import Foundation
@testable import MoneyUpCore
import XCTest

final class LoanAllowancePacingTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") {
            calendar.timeZone = utc
        }
        return calendar
    }

    func testLoanPaymentIsBalancedAndSeparatesPrincipalInterestAndFees() throws {
        let currency = try CurrencyCode("MYR")
        let cashID = UUID()
        let loanID = UUID()
        let interestID = UUID()
        let feeID = UUID()
        let entry = try TransactionFactory.loanPayment(
            principal: try Money(350, currency: currency),
            interest: try Money(30, currency: currency),
            fees: try Money(8, currency: currency),
            paidFrom: cashID,
            loanAccountID: loanID,
            interestCategoryID: interestID,
            feeCategoryID: feeID
        )

        XCTAssertEqual(entry.sourceSystem, TransactionFactory.loanPaymentSource)
        XCTAssertEqual(entry.balanceByCurrency[currency], .zero)
        XCTAssertEqual(entry.postings.first { $0.accountID == cashID }?.money.amount, -388)
        XCTAssertEqual(entry.postings.first { $0.accountID == loanID }?.money.amount, 350)
        XCTAssertEqual(entry.postings.first { $0.accountID == interestID }?.money.amount, 30)
        XCTAssertEqual(entry.postings.first { $0.accountID == feeID }?.money.amount, 8)
    }

    func testLoanSummaryUsesLedgerPrincipalAndTracksActivityTotals() throws {
        let currency = try CurrencyCode("MYR")
        let zero = Money.zero(currency: currency)
        let activity = try LoanActivity(
            kind: .repayment,
            occurredAt: Date(timeIntervalSince1970: 200),
            principal: try Money(350, currency: currency),
            interest: try Money(30, currency: currency),
            fees: zero,
            journalEntryID: UUID()
        )
        let plan = try LoanPlan(
            accountID: UUID(),
            name: "Car loan",
            originalPrincipal: try Money(20_500, currency: currency),
            openedAt: Date(timeIntervalSince1970: 100),
            activities: [activity]
        )
        let summary = try plan.summary(
            currentPrincipal: try Money(15_285, currency: currency)
        )

        XCTAssertEqual(summary.remainingPrincipal.amount, 15_285)
        XCTAssertEqual(summary.totalPrincipalAdvanced.amount, 20_500)
        XCTAssertEqual(summary.principalPaid.amount, 5_215)
        XCTAssertEqual(summary.totalInterestPaid.amount, 30)
    }

    func testLegacyLoanAndAllowanceDecodeWithNeutralPurposes() throws {
        let currency = try CurrencyCode("SGD")
        let loan = try LoanPlan(
            accountID: UUID(),
            name: "Home",
            purpose: .home,
            originalPrincipal: try Money(100, currency: currency),
            openedAt: Date(timeIntervalSince1970: 100)
        )
        var loanObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(loan)) as? [String: Any]
        )
        loanObject.removeValue(forKey: "purpose")
        let decodedLoan = try JSONDecoder().decode(
            LoanPlan.self,
            from: JSONSerialization.data(withJSONObject: loanObject)
        )
        XCTAssertEqual(decodedLoan.purpose, .other)

        let allowance = try AllowancePlan(
            name: "Meal",
            amount: try Money(12, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: UUID(),
            startsAt: Date(timeIntervalSince1970: 100)
        )
        var allowanceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(allowance))
                as? [String: Any]
        )
        allowanceObject.removeValue(forKey: "fundingMode")
        allowanceObject.removeValue(forKey: "linkedAccountID")
        let decodedAllowance = try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: allowanceObject)
        )
        XCTAssertEqual(decodedAllowance.fundingMode, .benefitLimit)
        XCTAssertNil(decodedAllowance.linkedAccountID)
    }

    func testDailyAllowanceExpiresInsteadOfRollingOver() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let usage = try AllowanceUsage(
            amount: try Money(4, currency: currency),
            occurredAt: start.addingTimeInterval(3_600)
        )
        let plan = try AllowancePlan(
            name: "Meal allowance",
            amount: try Money(12, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .none,
            usages: [usage]
        )

        XCTAssertEqual(try plan.summary(asOf: start.addingTimeInterval(7_200)).remaining.amount, 8)
        XCTAssertEqual(try plan.summary(asOf: start.addingTimeInterval(90_000)).remaining.amount, 12)
    }

    func testCappedAllowanceCarriesOnlyUpToConfiguredCap() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .capped,
            rolloverCap: try Money(5, currency: currency)
        )

        XCTAssertEqual(
            try plan.summary(asOf: start.addingTimeInterval(90_000)).entitlement.amount,
            15
        )
    }

    func testBudgetPacingRoundsOnceToCurrencyMinorUnits() throws {
        let currency = try CurrencyCode("SGD")
        let asOf = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))
        )
        let daily = try BudgetPaceCalculator.pace(
            remaining: try Money(310, currency: currency),
            cadence: .daily,
            asOf: asOf,
            calendar: utcCalendar
        )
        let weekly = try BudgetPaceCalculator.pace(
            remaining: try Money(310, currency: currency),
            cadence: .weekly,
            asOf: asOf,
            calendar: utcCalendar
        )

        XCTAssertEqual(daily.remainingDayCount, 29)
        XCTAssertEqual(daily.available.amount, Decimal(string: "10.69"))
        XCTAssertEqual(weekly.available.amount, Decimal(string: "74.83"))
    }

    func testPaceSpreadResolvesEveryCadenceFromOneInstant() throws {
        let currency = try CurrencyCode("SGD")
        let asOf = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))
        )
        let remaining = try Money(310, currency: currency)
        let spread = try BudgetPaceCalculator.spread(
            remaining: remaining,
            asOf: asOf,
            calendar: utcCalendar
        )

        // The month bucket is the whole remainder; the shorter buckets are the
        // same figures the single-cadence calculator already produces.
        XCTAssertEqual(spread.monthly.available, remaining)
        XCTAssertEqual(spread.monthly.cadence, .monthly)
        XCTAssertEqual(
            spread.weekly.available,
            try BudgetPaceCalculator.pace(
                remaining: remaining,
                cadence: .weekly,
                asOf: asOf,
                calendar: utcCalendar
            ).available
        )
        XCTAssertEqual(
            spread.daily.available,
            try BudgetPaceCalculator.pace(
                remaining: remaining,
                cadence: .daily,
                asOf: asOf,
                calendar: utcCalendar
            ).available
        )
        for pace in [spread.monthly, spread.weekly, spread.daily] {
            XCTAssertEqual(pace.remainingDayCount, 29)
        }
        XCTAssertLessThanOrEqual(spread.daily.available.amount, spread.weekly.available.amount)
        XCTAssertLessThanOrEqual(spread.weekly.available.amount, spread.monthly.available.amount)
    }

    func testPaceSpreadCollapsesToOneDayOnTheFinalReportingDay() throws {
        let currency = try CurrencyCode("SGD")
        let asOf = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 9))
        )
        let remaining = try Money(45, currency: currency)
        let spread = try BudgetPaceCalculator.spread(
            remaining: remaining,
            asOf: asOf,
            calendar: utcCalendar
        )

        // One day left means every horizon is the same money; a week bucket
        // must never reach past the month it belongs to.
        XCTAssertEqual(spread.monthly.available, remaining)
        XCTAssertEqual(spread.weekly.available, remaining)
        XCTAssertEqual(spread.daily.available, remaining)
        XCTAssertEqual(spread.daily.remainingDayCount, 1)
    }

    func testHistorySummarySeparatesSpendIncomeAndRefunds() throws {
        let currency = try CurrencyCode("SGD")
        let cash = LedgerAccount(name: "Cash", kind: .asset, currency: currency)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let expense = try TransactionFactory.expense(
            amount: try Money(20, currency: currency),
            paidFrom: cash.id,
            category: food.id
        )
        let refund = try TransactionFactory.refund(
            amount: try Money(5, currency: currency),
            returnedTo: cash.id,
            category: food.id
        )
        let income = try TransactionFactory.income(
            amount: try Money(100, currency: currency),
            depositedInto: cash.id,
            category: salary.id
        )
        let summary = try HistoryQuery().summary(
            for: [expense, refund, income],
            accounts: [cash, food, salary]
        )

        XCTAssertEqual(summary.spendingByCurrency[currency], 20)
        XCTAssertEqual(summary.refundsByCurrency[currency], 5)
        XCTAssertEqual(summary.incomeByCurrency[currency], 100)
        XCTAssertEqual(summary.amountsByCurrency[currency], 85)
    }
}
