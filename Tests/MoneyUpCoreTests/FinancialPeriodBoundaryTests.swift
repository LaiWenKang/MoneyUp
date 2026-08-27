import Foundation
@testable import MoneyUpCore
import XCTest

final class FinancialPeriodBoundaryTests: XCTestCase {
    func testReportingCalendarIsGregorianWithRequestedStableTimeZone() {
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Asia/Singapore"
        )

        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone.identifier, "Asia/Singapore")
    }

    func testBoundaryInstantBelongsToExactlyTheFollowingPeriod() throws {
        let boundary = Date(timeIntervalSince1970: 10_000)
        let previous = DateInterval(
            start: boundary.addingTimeInterval(-1_000),
            end: boundary
        )
        let following = DateInterval(
            start: boundary,
            end: boundary.addingTimeInterval(1_000)
        )

        XCTAssertFalse(FinancialPeriodBoundary.contains(boundary, in: previous))
        XCTAssertTrue(FinancialPeriodBoundary.contains(boundary, in: following))
    }

    func testInclusiveDayIntervalUsesCalendarAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let noon = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))
        )
        let interval = try XCTUnwrap(
            FinancialPeriodBoundary.inclusiveDayInterval(
                from: noon,
                through: noon,
                calendar: calendar
            )
        )
        let followingMidnight = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))
        )

        XCTAssertEqual(interval.duration, 23 * 60 * 60, accuracy: 0.001)
        XCTAssertTrue(FinancialPeriodBoundary.contains(noon, in: interval))
        XCTAssertFalse(
            FinancialPeriodBoundary.contains(followingMidnight, in: interval)
        )
    }

    func testOpenEndedHistoryWindowUsesTheSameHalfOpenContract() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)

        XCTAssertTrue(
            FinancialPeriodBoundary.contains(start, start: start, endExclusive: end)
        )
        XCTAssertFalse(
            FinancialPeriodBoundary.contains(end, start: start, endExclusive: end)
        )
        XCTAssertTrue(
            FinancialPeriodBoundary.contains(end, start: nil, endExclusive: nil)
        )
    }

    func testOriginDayKeyRangeHonorsPartialDayHalfOpenBounds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let start = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 2,
                    day: 3,
                    hour: 12
                )
            )
        )
        let end = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 2,
                    day: 5,
                    hour: 12
                )
            )
        )

        XCTAssertEqual(
            FinancialPeriodBoundary.dayKeyRange(
                for: DateInterval(start: start, end: end),
                calendar: calendar
            ),
            20260204..<20260206
        )
    }
}
