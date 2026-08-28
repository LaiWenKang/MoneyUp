import Foundation
@testable import MoneyUpCore
import XCTest

final class ScheduledAndHoldingTests: XCTestCase {
    func testScheduleLifecycleConfirmsThenResolvesExactlyOneOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 31
        )))
        var schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(1_000, currency: CurrencyCode("SGD")),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: anchor,
            frequency: .monthly
        )
        let january = schedule.currentOccurrenceID

        try schedule.confirmCurrent(occurrenceID: january)
        XCTAssertTrue(schedule.isCurrentOccurrenceConfirmed)
        XCTAssertEqual(schedule.nextOccurrence, anchor)
        try schedule.resolveCurrent(
            occurrenceID: january,
            as: .skipped,
            calendar: calendar
        )

        XCTAssertEqual(schedule.resolutions.first?.kind, .skipped)
        XCTAssertEqual(calendar.component(.day, from: schedule.nextOccurrence), 28)
        XCTAssertThrowsError(
            try schedule.resolveCurrent(
                occurrenceID: january,
                as: .skipped,
                calendar: calendar
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .staleOccurrence)
        }

        try schedule.resolveCurrent(
            occurrenceID: schedule.currentOccurrenceID,
            as: .skipped,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: schedule.nextOccurrence), 31)
    }

    func testSchedulePauseResumeEndAndSeriesEditInvalidateStaleOccurrence() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        var schedule = try ScheduledTransaction(
            kind: .income,
            name: "Salary",
            amount: try Money(5_000, currency: CurrencyCode("SGD")),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: date,
            frequency: .monthly
        )
        try schedule.pause()
        XCTAssertEqual(schedule.status, .paused)
        XCTAssertNil(schedule.occurrence(onOrAfter: date))
        try schedule.resume()
        XCTAssertTrue(schedule.isActive)

        let oldOccurrence = schedule.currentOccurrenceID
        let edited = try schedule.updating(
            kind: schedule.kind,
            name: "Updated salary",
            amount: schedule.amount,
            accountID: schedule.accountID,
            categoryAccountID: schedule.categoryAccountID,
            nextOccurrence: date.addingTimeInterval(86_400),
            frequency: .weekly
        )
        XCTAssertNotEqual(edited.currentOccurrenceID, oldOccurrence)
        XCTAssertEqual(edited.resolutions, schedule.resolutions)

        try schedule.end(at: date)
        XCTAssertEqual(schedule.status, .ended)
        XCTAssertThrowsError(try schedule.resume())
    }

    func testLegacyScheduleJSONDecodesWithoutLifecycleFields() throws {
        struct LegacySchedule: Encodable {
            let id: UUID
            let kind: JournalEntryKind
            let name: String
            let amount: Money
            let accountID: UUID
            let categoryAccountID: UUID
            let nextOccurrence: Date
            let frequency: RecurrenceFrequency
            let isActive: Bool
        }
        let due = Date(timeIntervalSinceReferenceDate: 3_000)
        let legacy = LegacySchedule(
            id: UUID(),
            kind: .expense,
            name: "Legacy rent",
            amount: try Money(900, currency: CurrencyCode("SGD")),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: due,
            frequency: .monthly,
            isActive: false
        )

        let decoded = try JSONDecoder().decode(
            ScheduledTransaction.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(decoded.status, .paused)
        XCTAssertEqual(decoded.recurrenceAnchor, due)
        XCTAssertEqual(decoded.currentOccurrenceIndex, 0)
        XCTAssertTrue(decoded.resolutions.isEmpty)
    }

    func testScheduleRejectsNonFiniteLifecycleDatesAtEveryWriteBoundary() throws {
        let sgd = try CurrencyCode("SGD")
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(
            try ScheduledTransaction(
                kind: .expense,
                name: "Invalid",
                amount: try Money(1, currency: sgd),
                accountID: UUID(),
                categoryAccountID: UUID(),
                nextOccurrence: invalid,
                frequency: .monthly
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .invalidLifecycle)
        }

        var schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Valid",
            amount: try Money(1, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: Date(timeIntervalSinceReferenceDate: 1_000),
            frequency: .monthly
        )
        XCTAssertThrowsError(
            try schedule.confirmCurrent(
                occurrenceID: schedule.currentOccurrenceID,
                at: invalid
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .invalidLifecycle)
        }
        XCTAssertThrowsError(try schedule.end(at: invalid)) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .invalidLifecycle)
        }
        XCTAssertThrowsError(
            try ScheduledOccurrenceResolution(
                occurrenceID: schedule.currentOccurrenceID,
                scheduledFor: schedule.nextOccurrence,
                kind: .skipped,
                linkedEntryID: nil,
                resolvedAt: invalid
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .invalidLifecycle)
        }
    }

    func testScheduledJournalLinkCanBeRelinkedThenExplicitlyDeleted() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let oldEntryID = UUID()
        let replacementID = UUID()
        var schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(100, currency: CurrencyCode("SGD")),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: Date(timeIntervalSinceReferenceDate: 1_000),
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: calendar.timeZone.identifier
        )
        try schedule.resolveCurrent(
            occurrenceID: schedule.currentOccurrenceID,
            as: .posted,
            linkedEntryID: oldEntryID,
            at: Date(timeIntervalSinceReferenceDate: 1_500),
            calendar: calendar
        )

        try schedule.relinkEntry(from: oldEntryID, to: replacementID)
        XCTAssertEqual(schedule.resolutions.first?.linkedEntryID, replacementID)
        let deletedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        try schedule.markLinkedEntryDeleted(replacementID, at: deletedAt)
        XCTAssertEqual(schedule.resolutions.first?.kind, .entryDeleted)
        XCTAssertNil(schedule.resolutions.first?.linkedEntryID)
        XCTAssertEqual(schedule.resolutions.first?.entryDeletedAt, deletedAt)

        let restored = try JSONDecoder().decode(
            ScheduledTransaction.self,
            from: JSONEncoder().encode(schedule)
        )
        XCTAssertEqual(restored, schedule)
    }

    func testScheduleDecodeRejectsNegativeAndMisanchoredLifecycleState() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let schedule = try ScheduledTransaction(
            kind: .income,
            name: "Salary",
            amount: try Money(100, currency: CurrencyCode("SGD")),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: Date(timeIntervalSinceReferenceDate: 1_000),
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: calendar.timeZone.identifier
        )
        let encoded = try JSONEncoder().encode(schedule)
        var negative = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        negative["currentOccurrenceIndex"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(
            ScheduledTransaction.self,
            from: JSONSerialization.data(withJSONObject: negative)
        ))

        var misanchored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        misanchored["nextOccurrence"] = try XCTUnwrap(
            misanchored["nextOccurrence"] as? Double
        ) + 3_600
        XCTAssertThrowsError(try JSONDecoder().decode(
            ScheduledTransaction.self,
            from: JSONSerialization.data(withJSONObject: misanchored)
        ))
    }

    func testDirectOccurrencePredicateMatchesAnchoredMonthlyDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sgd = try CurrencyCode("SGD")
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 31,
            hour: 9
        )))
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Month end",
            amount: try Money(20, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: anchor,
            frequency: .monthly
        )
        let februaryEnd = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 2,
            day: 28,
            hour: 12
        )))
        let februaryWrong = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 2,
            day: 27,
            hour: 12
        )))

        XCTAssertTrue(schedule.occurs(on: februaryEnd, calendar: calendar))
        XCTAssertFalse(schedule.occurs(on: februaryWrong, calendar: calendar))
    }

    func testMonthlyScheduleGeneratesBoundedOccurrences() throws {
        let sgd = try CurrencyCode("SGD")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))
        )
        let end = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(1_000, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: start,
            frequency: .monthly
        )

        let dates = schedule.occurrences(through: end, calendar: calendar)

        XCTAssertEqual(dates.count, 4)
        XCTAssertEqual(calendar.component(.month, from: dates.last!), 4)
    }

    func testScheduleRejectsTransferAndZeroAmount() throws {
        let sgd = try CurrencyCode("SGD")

        XCTAssertThrowsError(
            try ScheduledTransaction(
                kind: .transfer,
                name: "Transfer",
                amount: try Money(1, currency: sgd),
                accountID: UUID(),
                categoryAccountID: UUID(),
                nextOccurrence: Date(),
                frequency: .monthly
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .unsupportedKind)
        }

        XCTAssertThrowsError(
            try ScheduledTransaction(
                kind: .expense,
                name: "Invalid",
                amount: Money.zero(currency: sgd),
                accountID: UUID(),
                categoryAccountID: UUID(),
                nextOccurrence: Date(),
                frequency: .monthly
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .amountMustBePositive)
        }
    }

    func testScheduleFindsFirstOccurrenceThatHasNotPassed() throws {
        let sgd = try CurrencyCode("SGD")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))
        )
        let reference = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))
        )
        let expected = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(1_000, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: start,
            frequency: .monthly
        )

        XCTAssertEqual(
            schedule.occurrence(onOrAfter: reference, calendar: calendar),
            expected
        )
    }

    func testScheduleKeepsFutureAnchorAndIgnoresInactiveSchedule() throws {
        let sgd = try CurrencyCode("SGD")
        let reference = Date(timeIntervalSince1970: 1_000)
        let future = Date(timeIntervalSince1970: 2_000)
        let active = try ScheduledTransaction(
            kind: .income,
            name: "Salary",
            amount: try Money(5_000, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: future,
            frequency: .monthly
        )
        let inactive = try ScheduledTransaction(
            kind: .income,
            name: "Old salary",
            amount: try Money(4_000, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: future,
            frequency: .monthly,
            isActive: false
        )

        XCTAssertEqual(active.occurrence(onOrAfter: reference), future)
        XCTAssertNil(inactive.occurrence(onOrAfter: reference))
    }

    func testMonthlyScheduleReturnsToAnchorDayAfterShortMonth() throws {
        let sgd = try CurrencyCode("SGD")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(
                calendar.date(
                    from: DateComponents(year: year, month: month, day: day)
                )
            )
        }

        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Month end",
            amount: try Money(100, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: try date(2026, 1, 31),
            frequency: .monthly
        )

        XCTAssertEqual(
            schedule.occurrences(through: try date(2026, 3, 31), calendar: calendar),
            [try date(2026, 1, 31), try date(2026, 2, 28), try date(2026, 3, 31)]
        )
        XCTAssertEqual(
            schedule.occurrence(onOrAfter: try date(2026, 3, 1), calendar: calendar),
            try date(2026, 3, 31)
        )
    }

    func testInvestmentMarketValueUsesDecimalArithmetic() throws {
        let usd = try CurrencyCode("USD")
        let holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: " mu ",
            name: "Micron",
            quantity: Decimal(string: "1.25")!,
            price: try Money(Decimal(string: "100.40")!, currency: usd),
            priceAsOf: Date()
        )

        let value = try holding.marketValue()

        XCTAssertEqual(holding.symbol, "MU")
        XCTAssertEqual(value?.amount, Decimal(string: "125.500")!)
        XCTAssertEqual(value?.currency, usd)
    }
}
