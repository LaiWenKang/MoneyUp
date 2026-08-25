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

        let summary = HistoryQuery().summary(for: entries, accounts: fixture.accounts)

        XCTAssertEqual(summary.transactionCount, 4)
        XCTAssertEqual(summary.amountsByCurrency[fixture.sgd], -25)
        XCTAssertEqual(summary.amountsByCurrency[fixture.usd], 100)
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

        let summary = HistoryQuery().summary(for: [transfer], accounts: fixture.accounts)

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
