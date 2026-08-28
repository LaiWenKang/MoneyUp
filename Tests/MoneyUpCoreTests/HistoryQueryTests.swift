import Foundation
@testable import MoneyUpCore
import XCTest

final class HistoryQueryTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testCombinedFiltersUseInclusiveDaysAndAmountRange() throws {
        let fixture = try Fixture()
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!
        let endExclusive = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!
        let expense = try fixture.expense(
            amount: 12.50,
            occurredAt: start.addingTimeInterval(60),
            payee: "Café Měng"
        )
        let outsideDate = try fixture.expense(
            amount: 12.50,
            occurredAt: endExclusive,
            payee: "Café Měng"
        )
        let outsideAmount = try fixture.expense(
            amount: 40,
            occurredAt: start.addingTimeInterval(120),
            payee: "Café Měng"
        )
        let wrongAccount = try TransactionFactory.expense(
            amount: try Money(12.50, currency: fixture.sgd),
            paidFrom: fixture.secondWallet.id,
            category: fixture.food.id,
            occurredAt: start.addingTimeInterval(180),
            payee: "Café Měng"
        )
        let wrongCategory = try TransactionFactory.expense(
            amount: try Money(12.50, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.transport.id,
            occurredAt: start.addingTimeInterval(240),
            payee: "Café Měng"
        )
        let query = HistoryQuery(
            searchText: "CAFE MENG",
            kind: .expense,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            startDate: start,
            endDateExclusive: endExclusive,
            minimumAmount: 10,
            maximumAmount: 20
        )

        XCTAssertEqual(
            query.filteredEntries(
                [outsideDate, outsideAmount, wrongAccount, wrongCategory, expense],
                accounts: fixture.accounts,
                locale: Locale(identifier: "en_US")
            ).map(\.id),
            [expense.id]
        )
    }

    func testSearchMatchesChineseAccountAndFormattedAmount() throws {
        let fixture = try Fixture()
        let entry = try fixture.expense(amount: 28.80, payee: "市场")

        XCTAssertEqual(
            HistoryQuery(searchText: "日常钱包")
                .filteredEntries([entry], accounts: fixture.accounts).count,
            1
        )
        XCTAssertEqual(
            HistoryQuery(searchText: "28.8 SGD")
                .filteredEntries([entry], accounts: fixture.accounts).count,
            1
        )
        XCTAssertEqual(
            HistoryQuery(searchText: "28,8 SGD")
                .filteredEntries(
                    [entry],
                    accounts: fixture.accounts,
                    locale: Locale(identifier: "de_DE")
                ).count,
            1
        )
    }

    func testForeignTransferAmountRangeMatchesEitherUserAccountSide() throws {
        let fixture = try Fixture()
        let transfer = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(135, currency: fixture.sgd),
            destinationAmount: try Money(100, currency: fixture.usd),
            from: fixture.wallet.id,
            to: fixture.usAccount.id,
            sourceTradingAccountID: fixture.sgdTrading.id,
            destinationTradingAccountID: fixture.usdTrading.id
        )

        XCTAssertEqual(
            HistoryQuery(kind: .transfer, minimumAmount: 99, maximumAmount: 101)
                .filteredEntries([transfer], accounts: fixture.accounts).count,
            1
        )
    }

    func testSplitAmountRangeMatchesTotalAndIndividualAllocations() throws {
        let fixture = try Fixture()
        let split = try TransactionFactory.splitExpense(
            amount: try Money(100, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            splits: [
                TransactionSplitLine(
                    categoryAccountID: fixture.food.id,
                    amount: try Money(40, currency: fixture.sgd)
                ),
                TransactionSplitLine(
                    categoryAccountID: fixture.transport.id,
                    amount: try Money(60, currency: fixture.sgd)
                )
            ]
        )

        XCTAssertEqual(
            HistoryQuery(minimumAmount: 100, maximumAmount: 100)
                .filteredEntries([split], accounts: fixture.accounts).map(\.id),
            [split.id]
        )
        XCTAssertEqual(
            HistoryQuery(minimumAmount: 40, maximumAmount: 40)
                .filteredEntries([split], accounts: fixture.accounts).map(\.id),
            [split.id]
        )
    }

    func testSummaryReportsNetIncomeLessSpendingPerCurrency() throws {
        let fixture = try Fixture()
        let expense = try fixture.expense(amount: 30)
        let refund = try TransactionFactory.refund(
            amount: try Money(5, currency: fixture.sgd),
            returnedTo: fixture.wallet.id,
            category: fixture.food.id
        )
        let income = try TransactionFactory.income(
            amount: try Money(100, currency: fixture.usd),
            depositedInto: fixture.usAccount.id,
            category: fixture.salary.id
        )
        let transfer = try TransactionFactory.transfer(
            amount: try Money(10, currency: fixture.sgd),
            from: fixture.wallet.id,
            to: fixture.secondWallet.id
        )
        let entries = [expense, refund, income, transfer]

        let summary = try HistoryQuery().summary(for: entries, accounts: fixture.accounts)

        XCTAssertEqual(summary.transactionCount, 4)
        XCTAssertEqual(summary.amountsByCurrency[fixture.sgd], -25)
        XCTAssertEqual(summary.amountsByCurrency[fixture.usd], 100)
    }

    func testDuplicateAccountIdentityCannotTrapHistoryLookup() throws {
        let fixture = try Fixture()
        let entry = try fixture.expense(amount: 30)
        let duplicate = LedgerAccount(
            id: fixture.wallet.id,
            name: "Conflicting duplicate",
            kind: .liability,
            currency: fixture.sgd
        )
        let accounts = fixture.accounts + [duplicate]

        XCTAssertEqual(
            HistoryQuery(searchText: fixture.wallet.name)
                .filteredEntries([entry], accounts: accounts).map(\.id),
            [entry.id]
        )
        XCTAssertEqual(
            try HistoryQuery().summary(for: [entry], accounts: accounts)
                .amountsByCurrency[fixture.sgd],
            -30
        )
    }

    func testSummaryKeepsForeignTransferSidesSeparateByCurrency() throws {
        let fixture = try Fixture()
        let transfer = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(135, currency: fixture.sgd),
            destinationAmount: try Money(100, currency: fixture.usd),
            from: fixture.wallet.id,
            to: fixture.usAccount.id,
            sourceTradingAccountID: fixture.sgdTrading.id,
            destinationTradingAccountID: fixture.usdTrading.id
        )

        let summary = try HistoryQuery().summary(for: [transfer], accounts: fixture.accounts)

        XCTAssertEqual(summary.amountsByCurrency[fixture.sgd], -135)
        XCTAssertEqual(summary.amountsByCurrency[fixture.usd], 100)
    }

    func testRefundFilterDoesNotIncludeOrdinaryExpenses() throws {
        let fixture = try Fixture()
        let expense = try fixture.expense(amount: 8)
        let refund = try TransactionFactory.refund(
            amount: try Money(3, currency: fixture.sgd),
            returnedTo: fixture.wallet.id,
            category: fixture.food.id
        )

        XCTAssertEqual(
            HistoryQuery(kind: .refund)
                .filteredEntries([expense, refund], accounts: fixture.accounts)
                .map(\.id),
            [refund.id]
        )
    }

    func testCategorySetUsesStableIDsAndTheSamePostingCurrency() throws {
        let fixture = try Fixture()
        let duplicateName = LedgerAccount(name: fixture.food.name, kind: .expense)
        let food = try fixture.expense(amount: 10)
        let transport = try TransactionFactory.expense(
            amount: Money(20, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.transport.id
        )
        let sameNameWrongID = try TransactionFactory.expense(
            amount: Money(30, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: duplicateName.id
        )
        let selectedCategoryWrongCurrency = try TransactionFactory.expense(
            amount: Money(40, currency: fixture.usd),
            paidFrom: fixture.usAccount.id,
            category: fixture.food.id
        )
        let query = HistoryQuery(
            categoryIDs: [fixture.food.id, fixture.transport.id],
            categoryPostingCurrency: fixture.sgd
        )

        XCTAssertEqual(
            query.filteredEntries(
                [
                    sameNameWrongID,
                    selectedCategoryWrongCurrency,
                    transport,
                    food
                ],
                accounts: fixture.accounts + [duplicateName]
            ).map(\.id),
            [transport.id, food.id]
        )
    }

    func testEmptyCategorySetFailsClosedInsteadOfMatchingAllHistory() throws {
        let fixture = try Fixture()
        let entry = try fixture.expense(amount: 10)

        XCTAssertTrue(
            HistoryQuery(categoryIDs: [])
                .filteredEntries([entry], accounts: fixture.accounts)
                .isEmpty
        )
    }

    func testChangedCategoryScopeClearsItsPreviousPostingCurrencyBoundary() throws {
        let fixture = try Fixture()
        var query = HistoryQuery(
            categoryIDs: [fixture.food.id, fixture.transport.id],
            categoryPostingCurrency: fixture.sgd
        )

        query.categoryID = fixture.food.id
        XCTAssertEqual(query.categoryIDs, Set([fixture.food.id]))
        XCTAssertNil(query.categoryPostingCurrency)

        query.categoryPostingCurrency = fixture.usd
        query.categoryIDs = nil
        XCTAssertNil(query.categoryPostingCurrency)

        XCTAssertNil(
            HistoryQuery(categoryPostingCurrency: fixture.sgd)
                .categoryPostingCurrency
        )
    }

    func testTenThousandEntryHistorySearchHasABoundedRegressionGuard() throws {
        let fixture = try Fixture()
        let entries = try (0..<10_000).map { index in
            try fixture.expense(
                amount: 1,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                payee: "Cafe \(index)"
            )
        }
        let query = HistoryQuery(
            searchText: "Cafe",
            kind: .expense,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            minimumAmount: 1,
            maximumAmount: 1
        )
        let clock = ContinuousClock()
        let started = clock.now

        let filtered = query.filteredEntries(
            entries,
            accounts: fixture.accounts,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(filtered.count, 10_000)
        XCTAssertEqual(
            try query.summary(for: filtered, accounts: fixture.accounts)
                .amountsByCurrency[fixture.sgd],
            -10_000
        )
        // CI is a broad algorithmic regression guard. The Golden PRD's
        // 300 ms p95 remains a physical oldest-device release measurement.
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}

private struct Fixture {
    let sgd: CurrencyCode
    let usd: CurrencyCode
    let wallet: LedgerAccount
    let secondWallet: LedgerAccount
    let usAccount: LedgerAccount
    let food: LedgerAccount
    let transport: LedgerAccount
    let salary: LedgerAccount
    let sgdTrading: LedgerAccount
    let usdTrading: LedgerAccount

    var accounts: [LedgerAccount] {
        [
            wallet, secondWallet, usAccount, food, transport, salary,
            sgdTrading, usdTrading
        ]
    }

    init() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        self.sgd = sgd
        self.usd = usd
        wallet = LedgerAccount(name: "日常钱包", kind: .asset, currency: sgd)
        secondWallet = LedgerAccount(name: "Savings", kind: .asset, currency: sgd)
        usAccount = LedgerAccount(name: "USD Cash", kind: .asset, currency: usd)
        food = LedgerAccount(name: "Food", kind: .expense)
        transport = LedgerAccount(name: "Transport", kind: .expense)
        salary = LedgerAccount(name: "Salary", kind: .income)
        sgdTrading = LedgerAccount(name: "FX SGD", kind: .trading, currency: sgd)
        usdTrading = LedgerAccount(name: "FX USD", kind: .trading, currency: usd)
    }

    func expense(
        amount: Decimal,
        occurredAt: Date = Date(timeIntervalSince1970: 0),
        payee: String? = nil
    ) throws -> JournalEntry {
        try TransactionFactory.expense(
            amount: Money(amount, currency: sgd),
            paidFrom: wallet.id,
            category: food.id,
            occurredAt: occurredAt,
            payee: payee
        )
    }
}
