import Foundation
@testable import MoneyUpCore
import XCTest

final class PeriodReportTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return try XCTUnwrap(calendar.date(from: components))
    }

    private func interval(
        _ period: ReportPeriod,
        containing date: Date
    ) throws -> DateInterval {
        try XCTUnwrap(period.interval(containing: date, calendar: calendar))
    }

    func testForeignCurrencySpendingIsReportedSeparatelyInsteadOfDropped() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let card = LedgerAccount(
            name: "USD card",
            kind: .liability,
            currency: usd,
            accountType: .creditCard
        )
        let food = LedgerAccount(name: "Food", kind: .expense)
        let salary = LedgerAccount(name: "Salary", kind: .income)

        let local = try TransactionFactory.expense(
            amount: try Money(30, currency: sgd),
            paidFrom: bank.id,
            category: food.id,
            occurredAt: try date(2026, 3, 5)
        )
        let abroad = try TransactionFactory.expense(
            amount: try Money(45, currency: usd),
            paidFrom: card.id,
            category: food.id,
            occurredAt: try date(2026, 3, 6)
        )
        let pay = try TransactionFactory.income(
            amount: try Money(4000, currency: sgd),
            depositedInto: bank.id,
            category: salary.id,
            occurredAt: try date(2026, 3, 1)
        )

        let report = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, card, food, salary],
            entries: [local, abroad, pay],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(report.baseFlow.income.amount, 4000)
        XCTAssertEqual(report.baseFlow.expense.amount, 30)
        XCTAssertEqual(report.baseFlow.net.amount, 3970)
        XCTAssertTrue(report.holdsUnconvertedActivity)
        XCTAssertEqual(report.foreignFlows.count, 1)
        XCTAssertEqual(report.foreignFlows.first?.currency, usd)
        XCTAssertEqual(report.foreignFlows.first?.expense.amount, 45)
        XCTAssertEqual(report.foreignFlows.first?.net.amount, -45)
        // The category breakdown stays in one currency so its bars remain
        // comparable; the foreign spend is accounted for above instead.
        XCTAssertEqual(report.categorySpending.map(\.amount.amount), [30])
    }

    func testTransfersAndAdjustmentsNeverAppearAsIncomeOrSpending() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd, accountType: .cash)
        let equity = LedgerAccount(
            name: "Opening",
            kind: .equity,
            systemRole: .openingBalances
        )
        let food = LedgerAccount(name: "Food", kind: .expense)

        let transfer = try TransactionFactory.transfer(
            amount: try Money(200, currency: sgd),
            from: bank.id,
            to: wallet.id,
            occurredAt: try date(2026, 3, 4)
        )
        let adjustment = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(75, currency: sgd),
            accountID: bank.id,
            equityAccountID: equity.id,
            accountIsLiability: false,
            occurredAt: try date(2026, 3, 7)
        )
        let lunch = try TransactionFactory.expense(
            amount: try Money(18, currency: sgd),
            paidFrom: wallet.id,
            category: food.id,
            occurredAt: try date(2026, 3, 8)
        )

        let report = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, wallet, equity, food],
            entries: [transfer, adjustment, lunch],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(report.baseFlow.income.amount, 0)
        XCTAssertEqual(report.baseFlow.expense.amount, 18)
        XCTAssertEqual(report.categorySpending.count, 1)
    }

    func testRefundsReduceCategorySpending() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let shopping = LedgerAccount(name: "Shopping", kind: .expense)

        let purchase = try TransactionFactory.expense(
            amount: try Money(120, currency: sgd),
            paidFrom: bank.id,
            category: shopping.id,
            occurredAt: try date(2026, 3, 2)
        )
        let refund = try TransactionFactory.refund(
            amount: try Money(40, currency: sgd),
            returnedTo: bank.id,
            category: shopping.id,
            occurredAt: try date(2026, 3, 9)
        )

        let report = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, shopping],
            entries: [purchase, refund],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(report.baseFlow.expense.amount, 80)
        XCTAssertEqual(report.categorySpending.first?.amount.amount, 80)
    }

    func testMidnightOnTheFirstBelongsOnlyToTheMonthItStarts() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let boundary = try TransactionFactory.expense(
            amount: try Money(12, currency: sgd),
            paidFrom: bank.id,
            category: food.id,
            occurredAt: try date(2026, 4, 1, hour: 0)
        )

        let march = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, food],
            entries: [boundary],
            baseCurrency: sgd,
            calendar: calendar
        )
        let april = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 4, 15)),
            accounts: [bank, food],
            entries: [boundary],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(march.baseFlow.expense.amount, 0)
        XCTAssertEqual(april.baseFlow.expense.amount, 12)
    }

    func testPersistedOriginDayControlsNormalizedReportAttribution() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(
            name: "Bank",
            kind: .asset,
            currency: sgd,
            accountType: .bank
        )
        let food = LedgerAccount(name: "Food", kind: .expense)
        let occurredAt = try date(2026, 3, 31, hour: 23)
        let expensePosting = Posting(
            accountID: food.id,
            money: try Money(12, currency: sgd)
        )
        let event = LedgerPostingEvent(
            entryID: UUID(),
            occurredAt: occurredAt,
            originDayKey: 20260401,
            posting: expensePosting
        )

        let march = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, food],
            postingEvents: [event],
            baseCurrency: sgd,
            calendar: calendar
        )
        let april = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 4, 15)),
            accounts: [bank, food],
            postingEvents: [event],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(march.baseFlow.expense.amount, 0)
        XCTAssertEqual(april.baseFlow.expense.amount, 12)
    }

    func testTrendSeriesCoversEveryMonthIncludingQuietOnes() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let april = try TransactionFactory.expense(
            amount: try Money(60, currency: sgd),
            paidFrom: bank.id,
            category: food.id,
            occurredAt: try date(2026, 4, 20)
        )

        let today = try date(2026, 6, 15)
        let report = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: today),
            trendInterval: try interval(.sixMonths, containing: today),
            accounts: [bank, food],
            entries: [april],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(report.monthlyFlows.count, 6)
        XCTAssertEqual(report.monthlyFlows.first?.month, try date(2026, 1, 1, hour: 0))
        XCTAssertEqual(report.monthlyFlows.last?.month, try date(2026, 6, 1, hour: 0))
        XCTAssertEqual(report.monthlyFlows.map(\.expense.amount), [0, 0, 0, 60, 0, 0])
        // June holds no activity, so the headline totals stay empty even
        // though the trend series has something to draw.
        XCTAssertTrue(report.isEmpty)
    }

    func testTrendDefaultsToTheSelectedReportingInterval() throws {
        let sgd = try CurrencyCode("SGD")
        let selected = try interval(.thisMonth, containing: try date(2026, 6, 15))

        let report = try FinanceCalculator.report(
            interval: selected,
            accounts: [],
            entries: [],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(report.trendInterval, selected)
        XCTAssertEqual(report.monthlyFlows.count, 1)
        XCTAssertEqual(report.monthlyFlows.first?.month, selected.start)
    }

    func testReadingsDescribeTheSamePeriodTheChartsShow() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let rent = LedgerAccount(name: "Rent", kind: .expense)
        let food = LedgerAccount(name: "Food", kind: .expense)

        let entries = [
            try TransactionFactory.income(
                amount: try Money(5000, currency: sgd),
                depositedInto: bank.id,
                category: salary.id,
                occurredAt: try date(2026, 3, 1)
            ),
            try TransactionFactory.expense(
                amount: try Money(1500, currency: sgd),
                paidFrom: bank.id,
                category: rent.id,
                occurredAt: try date(2026, 3, 2)
            ),
            try TransactionFactory.expense(
                amount: try Money(500, currency: sgd),
                paidFrom: bank.id,
                category: food.id,
                occurredAt: try date(2026, 3, 3)
            )
        ]

        let report = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, salary, rent, food],
            entries: entries,
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(try report.savingsRate(), Decimal(string: "0.6"))
        let largest = try XCTUnwrap(try report.largestCategory())
        XCTAssertEqual(largest.category.name, "Rent")
        XCTAssertEqual(largest.share, Decimal(string: "0.75"))
        XCTAssertEqual(report.categorySpending.map(\.name), ["Rent", "Food"])
    }

    func testEqualDuplicateCategoryNamesUseStableLedgerIdentityOrdering() throws {
        let sgd = try CurrencyCode("SGD")
        let firstID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let bank = LedgerAccount(
            name: "Bank",
            kind: .asset,
            currency: sgd,
            accountType: .bank
        )
        let second = LedgerAccount(id: secondID, name: "Food", kind: .expense)
        let first = LedgerAccount(id: firstID, name: "Food", kind: .expense)
        let entries = [
            try TransactionFactory.expense(
                amount: Money(10, currency: sgd),
                paidFrom: bank.id,
                category: second.id,
                occurredAt: try date(2026, 3, 2)
            ),
            try TransactionFactory.expense(
                amount: Money(10, currency: sgd),
                paidFrom: bank.id,
                category: first.id,
                occurredAt: try date(2026, 3, 2)
            )
        ]

        let report = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, second, first],
            entries: entries,
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(report.categorySpending.map(\.accountID), [firstID, secondID])
    }

    func testSavingsRateIsUndefinedWithoutIncome() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let lunch = try TransactionFactory.expense(
            amount: try Money(9, currency: sgd),
            paidFrom: bank.id,
            category: food.id,
            occurredAt: try date(2026, 3, 3)
        )

        let report = try FinanceCalculator.report(
            interval: try interval(.thisMonth, containing: try date(2026, 3, 15)),
            accounts: [bank, food],
            entries: [lunch],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertNil(try report.savingsRate())
        XCTAssertNotNil(try report.largestCategory())
    }

    func testPeriodsAreAlignedToWholeMonths() throws {
        let today = try date(2026, 6, 15)
        let thisMonth = try interval(.thisMonth, containing: today)
        let lastMonth = try interval(.lastMonth, containing: today)
        let sixMonths = try interval(.sixMonths, containing: today)
        let yearToDate = try interval(.yearToDate, containing: today)

        XCTAssertEqual(thisMonth.start, try date(2026, 6, 1, hour: 0))
        XCTAssertEqual(lastMonth.start, try date(2026, 5, 1, hour: 0))
        XCTAssertEqual(lastMonth.end, thisMonth.start)
        XCTAssertEqual(sixMonths.start, try date(2026, 1, 1, hour: 0))
        XCTAssertEqual(sixMonths.end, thisMonth.end)
        XCTAssertEqual(yearToDate.start, try date(2026, 1, 1, hour: 0))
        XCTAssertEqual(yearToDate.end, thisMonth.end)
    }

    func testMonthToDateComparisonUsesEqualElapsedWindows() throws {
        let now = try date(2026, 6, 15)
        let windows = try XCTUnwrap(
            MonthToDateComparisonIntervals(containing: now, calendar: calendar)
        )

        XCTAssertEqual(windows.current.start, try date(2026, 6, 1, hour: 0))
        XCTAssertEqual(windows.current.end, now)
        XCTAssertEqual(windows.previous.start, try date(2026, 5, 1, hour: 0))
        XCTAssertEqual(windows.previous.end, try date(2026, 5, 15))
        XCTAssertEqual(windows.current.duration, windows.previous.duration)
    }

    func testMonthToDateComparisonClampsToShorterPriorMonth() throws {
        let windows = try XCTUnwrap(
            MonthToDateComparisonIntervals(
                containing: try date(2026, 3, 31),
                calendar: calendar
            )
        )

        XCTAssertEqual(windows.current.start, try date(2026, 3, 1, hour: 0))
        XCTAssertEqual(windows.previous.start, try date(2026, 2, 1, hour: 0))
        XCTAssertEqual(windows.previous.end, try date(2026, 3, 1, hour: 0))
        XCTAssertLessThan(windows.previous.duration, windows.current.duration)
    }

    func testEmptyCalendarDayReturnsNoFalseZeroFlow() throws {
        let sgd = try CurrencyCode("SGD")
        let selected = try date(2026, 6, 15)
        let day = try XCTUnwrap(
            FinancialPeriodBoundary.inclusiveDayInterval(
                from: selected,
                through: selected,
                calendar: calendar
            )
        )

        let flows = try FinanceCalculator.dailyFlows(
            interval: day,
            accounts: [],
            entries: [],
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertTrue(flows.isEmpty)
    }

    func testCalendarDayKeepsEveryCurrencyInSeparateLabeledFlow() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd)
        let card = LedgerAccount(name: "Card", kind: .liability, currency: usd)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let selected = try date(2026, 6, 15)
        let day = try XCTUnwrap(
            FinancialPeriodBoundary.inclusiveDayInterval(
                from: selected,
                through: selected,
                calendar: calendar
            )
        )
        let entries = [
            try TransactionFactory.expense(
                amount: try Money(10, currency: sgd),
                paidFrom: bank.id,
                category: food.id,
                occurredAt: selected
            ),
            try TransactionFactory.expense(
                amount: try Money(20, currency: usd),
                paidFrom: card.id,
                category: food.id,
                occurredAt: selected
            )
        ]

        let flows = try FinanceCalculator.dailyFlows(
            interval: day,
            accounts: [bank, card, food],
            entries: entries,
            baseCurrency: sgd,
            calendar: calendar
        )

        XCTAssertEqual(Set(flows.map(\.currency)), [sgd, usd])
        XCTAssertEqual(flows.first { $0.currency == sgd }?.expense.amount, 10)
        XCTAssertEqual(flows.first { $0.currency == usd }?.expense.amount, 20)
    }

    func testBalancesByAccountMatchesPerAccountBalances() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let card = LedgerAccount(
            name: "USD card",
            kind: .liability,
            currency: usd,
            accountType: .creditCard
        )
        let food = LedgerAccount(name: "Food", kind: .expense)

        let entries = [
            try TransactionFactory.expense(
                amount: try Money(25, currency: sgd),
                paidFrom: bank.id,
                category: food.id,
                occurredAt: try date(2026, 3, 4)
            ),
            try TransactionFactory.expense(
                amount: try Money(40, currency: usd),
                paidFrom: card.id,
                category: food.id,
                occurredAt: try date(2026, 3, 5)
            )
        ]

        let balances = try FinanceCalculator.balancesByAccount(entries: entries)

        for account in [bank, card] {
            let currency = try XCTUnwrap(account.currency)
            XCTAssertEqual(
                balances[account.id]?[currency],
                try FinanceCalculator.balances(for: account.id, entries: entries)[currency]
            )
        }
        // Raw ledger signs: paying with a card credits the liability. The
        // user-facing sign flip belongs to displayBalance, not to this map.
        XCTAssertEqual(balances[card.id]?[usd]?.amount, -40)
        XCTAssertEqual(balances[bank.id]?[sgd]?.amount, -25)
    }
}
