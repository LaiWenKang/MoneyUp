import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

final class OverviewInsightTests: XCTestCase {
    func testChartMonthMidpointStaysInTheReportingMonthAcrossUTCAndDSTBoundaries() throws {
        for (zone, stamp, month) in [("Asia/Singapore", "2026-08-31T16:00:00Z", 9),
                                     ("America/New_York", "2026-03-01T05:00:00Z", 3)] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let start = try XCTUnwrap(ISO8601DateFormatter().date(from: stamp))
            let midpoint = start.reportingMonthMidpoint(calendar: calendar)
            XCTAssertEqual(calendar.component(.month, from: midpoint), month)
            XCTAssertEqual(midpoint.formattedForReporting(.dateTime.month(.twoDigits).locale(Locale(identifier: "en_US_POSIX")), calendar: calendar), String(format: "%02d", month))
            XCTAssertGreaterThan(midpoint, start)
            XCTAssertLessThan(midpoint, try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: start)))
        }
    }

    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    private func presentation(
        budget: BudgetWidgetSnapshot? = nil, review: Int? = 0,
        allowance: Int? = nil, count: Int = 0, days: Int? = nil
    ) -> SmartOverviewWidgetPresentation {
        .make(budget: budget ?? .available(percentUsed: 42, validUntil: expiry),
              insights: MoneyUpWidgetInsights(reviewCount: review, allowancePercentRemaining: allowance,
                activeCommitmentCount: count, daysUntilNextCommitment: days, validUntil: expiry), family: .systemSmall)
    }

    func testAutomaticFocusPrioritizesTheNextDueExpenseWithoutClaimingAllAreDue() {
        let state = presentation(budget: .available(percentUsed: 110, validUntil: expiry), review: 3, count: 8, days: 0)
        XCTAssertEqual(state.spotlight(for: .automatic), .commitment)
        XCTAssertEqual(state.commitment, .active(count: 8, daysUntilNext: 0))
        XCTAssertEqual(state.supportingComponents(for: .automatic).first, .budget)
    }

    func testOverLimitAndNegativeBudgetsPrecedeNonurgentReviewCounts() {
        for budget in [BudgetWidgetSnapshot.available(percentUsed: 101, validUntil: expiry), .negativeBudget(validUntil: expiry)] {
            XCTAssertEqual(presentation(budget: budget, review: 2).spotlight(for: .automatic), .budget)
        }
        XCTAssertEqual(presentation(review: 2).spotlight(for: .automatic), .review)
        XCTAssertEqual(presentation(review: 0).spotlight(for: .automatic), .budget)
    }

    func testExplicitFocusKeepsAValidZeroAndUnavailableFocusFallsBack() {
        XCTAssertEqual(presentation(review: 0).spotlight(for: .review), .review)
        XCTAssertEqual(presentation(allowance: 0).spotlight(for: .allowance), .allowance)
        XCTAssertEqual(presentation(allowance: nil).spotlight(for: .allowance), .budget)
        XCTAssertEqual(presentation(review: nil).spotlight(for: .review), .budget)
        XCTAssertEqual(presentation(count: 0).spotlight(for: .commitments), .commitment)
    }

    func testDisabledAndExpiredBudgetsCannotExposeCompanionMetricsForAnyFocus() {
        for budget in [BudgetWidgetSnapshot.disabled, .stale] {
            let state = presentation(budget: budget, review: 5, allowance: 20, count: 3, days: 0)
            for focus in SmartOverviewFocus.allCases {
                XCTAssertEqual(state.spotlight(for: focus), .budget)
                XCTAssertTrue(state.supportingComponents(for: focus).isEmpty)
            }
        }
    }

    func testSupportingMetricsNeverDuplicateTheHeadlineOrInventMissingValues() {
        let state = presentation(review: nil)
        XCTAssertEqual(state.supportingComponents(for: .automatic), [.commitment])
        XCTAssertEqual(presentation(allowance: 68).spotlight(for: .allowance), .allowance)
        XCTAssertFalse(presentation(allowance: 68).supportingComponents(for: .allowance).contains(.allowance))
    }

    func testSnapshotChangeIsExactAndDoesNotLabelTheFirstSnapshotAsZeroChange() throws {
        let currency = try CurrencyCode("SGD")
        let a = NetWorthHistoryPoint(id: UUID(), date: expiry, money: try Money(Decimal(string: "10.11")!, currency: currency))
        let b = NetWorthHistoryPoint(id: UUID(), date: expiry.addingTimeInterval(1), money: try Money(Decimal(string: "10.10")!, currency: currency))
        XCTAssertNil(try NetWorthHistoryPresentation.change(to: a, in: [a, b]))
        XCTAssertEqual(try NetWorthHistoryPresentation.change(to: b, in: [a, b])?.amount, Decimal(string: "-0.01"))
        let c = NetWorthHistoryPoint(id: UUID(), date: expiry.addingTimeInterval(2), money: try Money(20, currency: CurrencyCode("USD")))
        XCTAssertThrowsError(try NetWorthHistoryPresentation.change(to: c, in: [b, c]))
    }
}
