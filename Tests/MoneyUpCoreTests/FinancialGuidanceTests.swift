import Foundation
@testable import MoneyUpCore
import XCTest

final class FinancialGuidanceTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testFlexibleTodaySubtractsEveryRemainingFlexibleOccurrence() throws {
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

        let result = try XCTUnwrap(FinanceCalculator.flexibleToday(
            flexibleBudgetRemaining: try Money(630, currency: sgd),
            schedules: [weekly, foreign],
            flexibleCategoryIDs: [categoryID],
            asOf: date,
            calendar: calendar
        ))

        XCTAssertEqual(result.remainingDayCount, 6)
        XCTAssertEqual(result.flexibleCommitments.amount, 30)
        XCTAssertEqual(result.availableForRemainingPeriod.amount, 600)
        XCTAssertEqual(result.amountPerDay.amount, 100)
        XCTAssertEqual(result.amountForNextSevenDays.amount, 600)
        XCTAssertEqual(result.excludedForeignCommitments, [try Money(12, currency: usd)])
    }

    func testFlexibleTodayRoundsDailyGuidanceToCurrencyMinorUnits() throws {
        let jpy = try CurrencyCode("JPY")
        let calendar = utcCalendar
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 30,
            hour: 12
        ))!

        let result = try XCTUnwrap(FinanceCalculator.flexibleToday(
            flexibleBudgetRemaining: try Money(101, currency: jpy),
            schedules: [],
            flexibleCategoryIDs: [],
            asOf: date,
            calendar: calendar
        ))

        XCTAssertEqual(result.remainingDayCount, 2)
        XCTAssertEqual(result.amountPerDay.amount, 50)
        XCTAssertEqual(result.amountForNextSevenDays.amount, 101)
    }

    func testFlexibleTodayNeverSubtractsReservedOrDebtSchedules() throws {
        let sgd = try CurrencyCode("SGD")
        let accountID = UUID()
        let flexibleID = UUID()
        let rentID = UUID()
        let loanID = UUID()
        let calendar = utcCalendar
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 30,
            hour: 12
        ))!

        func schedule(_ name: String, categoryID: UUID, amount: Decimal) throws
            -> ScheduledTransaction {
            try ScheduledTransaction(
                kind: .expense,
                name: name,
                amount: try Money(amount, currency: sgd),
                accountID: accountID,
                categoryAccountID: categoryID,
                nextOccurrence: date,
                frequency: .monthly
            )
        }

        let result = try XCTUnwrap(FinanceCalculator.flexibleToday(
            flexibleBudgetRemaining: try Money(300, currency: sgd),
            schedules: [
                try schedule("Groceries", categoryID: flexibleID, amount: 40),
                try schedule("Rent", categoryID: rentID, amount: 1_500),
                try schedule("Loan", categoryID: loanID, amount: 400)
            ],
            flexibleCategoryIDs: [flexibleID],
            asOf: date,
            calendar: calendar
        ))

        XCTAssertEqual(result.flexibleCommitments.amount, 40)
        XCTAssertEqual(result.availableForRemainingPeriod.amount, 260)
        XCTAssertEqual(result.amountPerDay.amount, 130)
        XCTAssertEqual(result.amountForNextSevenDays.amount, 260)
    }

    func testFlexibleTodayUsesWholeRemainderOnFinalDay() throws {
        let sgd = try CurrencyCode("SGD")
        let date = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(year: 2026, month: 8, day: 31, hour: 23)
            )
        )

        let result = try XCTUnwrap(FinanceCalculator.flexibleToday(
            flexibleBudgetRemaining: try Money(
                Decimal(string: "19.99")!,
                currency: sgd
            ),
            schedules: [],
            flexibleCategoryIDs: [],
            asOf: date,
            calendar: utcCalendar
        ))

        XCTAssertEqual(result.remainingDayCount, 1)
        XCTAssertEqual(result.amountPerDay, result.availableForRemainingPeriod)
        XCTAssertEqual(result.amountForNextSevenDays, result.availableForRemainingPeriod)
    }

    func testFlexibleTodayReservesOverdueAndTodayBoundaryExactlyOnce() throws {
        let sgd = try CurrencyCode("SGD")
        let accountID = UUID()
        let categoryID = UUID()
        let calendar = utcCalendar
        let today = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 2
        )))
        let overdue = try ScheduledTransaction(
            kind: .expense,
            name: "Overdue monthly bill",
            amount: try Money(100, currency: sgd),
            accountID: accountID,
            categoryAccountID: categoryID,
            nextOccurrence: today.addingTimeInterval(-1),
            frequency: .monthly
        )
        let dueToday = try ScheduledTransaction(
            kind: .expense,
            name: "Due at day boundary",
            amount: try Money(40, currency: sgd),
            accountID: accountID,
            categoryAccountID: categoryID,
            nextOccurrence: today,
            frequency: .monthly
        )

        let result = try XCTUnwrap(FinanceCalculator.flexibleToday(
            flexibleBudgetRemaining: try Money(500, currency: sgd),
            schedules: [overdue, dueToday],
            flexibleCategoryIDs: [categoryID],
            asOf: today.addingTimeInterval(12 * 3_600),
            calendar: calendar
        ))

        XCTAssertEqual(result.flexibleCommitments.amount, 140)
        XCTAssertEqual(result.availableForRemainingPeriod.amount, 360)
        XCTAssertEqual(result.schedulesNeedingReview, 1)
    }

    func testFlexibleTodayReservesOverdueWeeklyAndFutureOccurrences() throws {
        let sgd = try CurrencyCode("SGD")
        let categoryID = UUID()
        let calendar = utcCalendar
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 2,
            hour: 12
        )))
        let firstDue = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 1,
            hour: 9
        )))
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Weekly bill",
            amount: try Money(20, currency: sgd),
            accountID: UUID(),
            categoryAccountID: categoryID,
            nextOccurrence: firstDue,
            frequency: .weekly
        )

        let result = try XCTUnwrap(FinanceCalculator.flexibleToday(
            flexibleBudgetRemaining: try Money(300, currency: sgd),
            schedules: [schedule],
            flexibleCategoryIDs: [categoryID],
            asOf: asOf,
            calendar: calendar
        ))

        XCTAssertEqual(result.flexibleCommitments.amount, 100)
        XCTAssertEqual(result.availableForRemainingPeriod.amount, 200)
        XCTAssertEqual(result.schedulesNeedingReview, 1)
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
        XCTAssertEqual(try forecast.budgetUsage(), Decimal(string: "0.55"))
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
