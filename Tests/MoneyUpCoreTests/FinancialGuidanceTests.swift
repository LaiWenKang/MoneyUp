import Foundation
@testable import MoneyUpCore
import XCTest

final class FinancialGuidanceTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testSafeToSpendSubtractsEveryRemainingBaseCurrencyOccurrence() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let accountID = UUID()
        let categoryID = UUID()
        let calendar = utcCalendar
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 26,
            hour: 12
        ))!
        let weekly = try ScheduledTransaction(
            kind: .expense,
            name: "Weekly plan",
            amount: try Money(30, currency: sgd),
            accountID: accountID,
            categoryAccountID: categoryID,
            nextOccurrence: calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 27,
                hour: 9
            ))!,
            frequency: .weekly
        )
        let foreign = try ScheduledTransaction(
            kind: .expense,
            name: "Foreign plan",
            amount: try Money(12, currency: usd),
            accountID: accountID,
            categoryAccountID: categoryID,
            nextOccurrence: calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 28,
                hour: 9
            ))!,
            frequency: .monthly
        )

        let result = try XCTUnwrap(FinanceCalculator.safeToSpend(
            budgetRemaining: try Money(630, currency: sgd),
            schedules: [weekly, foreign],
            asOf: date,
            calendar: calendar
        ))

        XCTAssertEqual(result.remainingDayCount, 6)
        XCTAssertEqual(result.scheduledCommitments.amount, 30)
        XCTAssertEqual(result.availableForRemainingPeriod.amount, 600)
        XCTAssertEqual(result.amountPerDay.amount, 100)
        XCTAssertEqual(result.excludedForeignCommitments, [try Money(12, currency: usd)])
    }

    func testSafeToSpendRoundsDailyGuidanceToCurrencyMinorUnits() throws {
        let jpy = try CurrencyCode("JPY")
        let calendar = utcCalendar
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 30,
            hour: 12
        ))!

        let result = try XCTUnwrap(FinanceCalculator.safeToSpend(
            budgetRemaining: try Money(101, currency: jpy),
            schedules: [],
            asOf: date,
            calendar: calendar
        ))

        XCTAssertEqual(result.remainingDayCount, 2)
        XCTAssertEqual(result.amountPerDay.amount, 50)
    }

    func testBudgetScenarioKeepsEveryProjectedTermCheckable() throws {
        let sgd = try CurrencyCode("SGD")
        let forecast = try FinanceCalculator.budgetScenario(
            currentSpent: try Money(400, currency: sgd),
            budgetLimit: try Money(1_000, currency: sgd),
            currentIncome: try Money(1_500, currency: sgd),
            additionalSpending: 150,
            additionalIncome: 200
        )

        XCTAssertEqual(forecast.projectedSpent.amount, 550)
        XCTAssertEqual(forecast.projectedRemaining.amount, 450)
        XCTAssertEqual(forecast.projectedIncome.amount, 1_700)
        XCTAssertEqual(forecast.projectedNet.amount, 1_150)
        XCTAssertEqual(forecast.budgetUsage, Decimal(string: "0.55"))
    }

    func testBudgetScenarioRejectsNegativeAdjustments() throws {
        let sgd = try CurrencyCode("SGD")

        XCTAssertThrowsError(
            try FinanceCalculator.budgetScenario(
                currentSpent: try Money(10, currency: sgd),
                budgetLimit: try Money(100, currency: sgd),
                currentIncome: try Money(100, currency: sgd),
                additionalSpending: -1,
                additionalIncome: 0
            )
        ) { error in
            XCTAssertEqual(error as? FinanceScenarioError, .negativeAdjustment)
        }
    }
}
