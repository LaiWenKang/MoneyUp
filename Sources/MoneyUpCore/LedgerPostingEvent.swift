import Foundation

/// The smallest lossless ledger projection needed for balances and reports.
///
/// Persistence can stream these values from its normalized encrypted index
/// without decoding or retaining payees, notes, source metadata, or complete
/// `JournalEntry` values. The entry identifier lets callers quarantine every
/// posting belonging to an entry when any one relationship is invalid.
public struct LedgerPostingEvent: Equatable, Sendable {
    public let entryID: UUID
    public let occurredAt: Date
    /// Stable origin-local YYYYMMDD used for financial-day attribution.
    public let originDayKey: Int
    public let posting: Posting

    public init(
        entryID: UUID,
        occurredAt: Date,
        originDayKey: Int,
        posting: Posting
    ) {
        self.entryID = entryID
        self.occurredAt = occurredAt
        self.originDayKey = originDayKey
        self.posting = posting
    }

    public func attributedDate(in calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = originDayKey / 10_000
        components.month = originDayKey / 100 % 100
        components.day = originDayKey % 100
        return calendar.date(from: components)
    }
}
