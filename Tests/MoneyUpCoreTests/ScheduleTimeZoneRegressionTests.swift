// Proposed focused tests for Tests/MoneyUpCoreTests. Not executed here.
import Foundation
@testable import MoneyUpCore
import XCTest

final class ScheduleTimeZoneRegressionTests: XCTestCase {
    func testForecastMatchesResolutionAcrossDSTLeapYearAndLegacyZones() throws {
        let iso = ISO8601DateFormatter()
        var reporting = Calendar(identifier: .gregorian)
        reporting.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let cases: [(RecurrenceFrequency, String, String?)] = [
            (.weekly, "2026-03-01T17:00:00Z", "America/Los_Angeles"),
            (.monthly, "2026-01-30T16:30:00Z", "Asia/Singapore"),
            (.yearly, "2024-02-28T16:30:00Z", "Asia/Singapore"),
            (.monthly, "2026-01-31T09:00:00Z", nil)
        ]
        for (frequency, anchorText, zone) in cases {
            let original = try ScheduledTransaction(
                kind: .expense, name: "Regression",
                amount: Money(10, currency: CurrencyCode("SGD")),
                accountID: UUID(), categoryAccountID: UUID(),
                nextOccurrence: XCTUnwrap(iso.date(from: anchorText)), frequency: frequency,
                recurrenceTimeZoneIdentifier: zone
            )
            var resolved = original
            var expected = [resolved.nextOccurrence]
            for _ in 0..<3 {
                let resolvedAt = resolved.nextOccurrence
                try resolved.resolveCurrent(
                    occurrenceID: resolved.currentOccurrenceID, as: .skipped,
                    at: resolvedAt, calendar: reporting
                )
                expected.append(resolved.nextOccurrence)
            }
            XCTAssertEqual(original.occurrences(through: expected[3], calendar: reporting), expected)
            for index in 1..<expected.count {
                XCTAssertEqual(original.occurrence(
                    onOrAfter: expected[index - 1].addingTimeInterval(1), calendar: reporting
                ), expected[index])
                XCTAssertTrue(original.occurs(on: expected[index], calendar: reporting))
            }
        }
    }

    func testForecastAndPostingUseTheSameStoredRecurrenceZone() throws {
        var reporting = Calendar(identifier: .gregorian)
        reporting.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let iso = ISO8601DateFormatter()
        let anchor = try XCTUnwrap(iso.date(from: "2026-01-30T16:30:00Z"))
        let expected = try XCTUnwrap(iso.date(from: "2026-02-27T16:30:00Z"))
        var schedule = try ScheduledTransaction(
            kind: .expense, name: "Month-end rent",
            amount: Money(10, currency: CurrencyCode("SGD")),
            accountID: UUID(), categoryAccountID: UUID(),
            nextOccurrence: anchor, frequency: .monthly,
            recurrenceTimeZoneIdentifier: "Asia/Singapore"
        )
        let forecast = schedule.occurrence(
            onOrAfter: anchor.addingTimeInterval(1), calendar: reporting
        )
        try schedule.resolveCurrent(
            occurrenceID: schedule.currentOccurrenceID, as: .skipped,
            at: anchor, calendar: reporting
        )
        XCTAssertEqual(schedule.nextOccurrence, expected)
        XCTAssertEqual(forecast, schedule.nextOccurrence)
        XCTAssertEqual(schedule.occurrences(through: expected, calendar: reporting), [expected])
        XCTAssertTrue(schedule.occurs(on: expected, calendar: reporting))
        XCTAssertFalse(schedule.occurs(on: expected.addingTimeInterval(86_400), calendar: reporting))
    }
}
