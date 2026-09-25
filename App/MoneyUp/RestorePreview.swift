import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct RestoreEntryPreviewMetadata: Equatable, Sendable {
    let oldestEntryDate: Date?
    let newestEntryDate: Date?
    let currencies: [CurrencyCode]

    static func make(from entries: [JournalEntry]) throws -> Self {
        var oldest: Date?
        var newest: Date?
        var currencies = Set<CurrencyCode>()
        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            oldest = oldest.map { min($0, entry.occurredAt) } ?? entry.occurredAt
            newest = newest.map { max($0, entry.occurredAt) } ?? entry.occurredAt
            currencies.formUnion(entry.postings.map(\.money.currency))
        }
        return Self(
            oldestEntryDate: oldest,
            newestEntryDate: newest,
            currencies: currencies.sorted()
        )
    }
}

struct RestorePreview: Equatable, Sendable {
    struct EntryDateSpan: Equatable, Sendable {
        let oldest: Date
        let newest: Date
    }

    struct BookSummary: Equatable, Sendable {
        let storedRecordCounts: [String: Int]
        let entryDateSpan: EntryDateSpan?
        let currencies: [CurrencyCode]
        let quarantinedRecordCount: Int
        /// Used only to render the entry span on the same fixed financial day
        /// boundary as its owning book. The identifier is never displayed.
        let reportingTimeZoneIdentifier: String

        func storedRecordCount(in collection: RecordCollection) -> Int {
            storedRecordCounts[collection.rawValue] ?? 0
        }

        var totalStoredRecordCount: Int {
            storedRecordCounts.values.reduce(into: 0) { total, count in
                let (candidate, overflow) = total.addingReportingOverflow(count)
                total = overflow ? .max : candidate
            }
        }
    }

    /// The old SQLCipher bytes still exist during key-cliff recovery, but no
    /// truthful counts can be derived without their destroyed device key.
    /// Keeping this as an enum prevents UI or tests from substituting an empty
    /// summary and presenting lost access as a zero-record book.
    enum CurrentBook: Equatable, Sendable {
        case available(BookSummary)
        case inaccessible

        var availableSummary: BookSummary? {
            guard case let .available(summary) = self else { return nil }
            return summary
        }
    }

    let archiveFormatVersion: Int
    let archiveSchemaVersion: Int32
    let current: CurrentBook
    let candidate: BookSummary

    init(
        archiveFormatVersion: Int,
        archiveSchemaVersion: Int32,
        current: CurrentBook,
        candidate: BookSummary
    ) {
        self.archiveFormatVersion = archiveFormatVersion
        self.archiveSchemaVersion = archiveSchemaVersion
        self.current = current
        self.candidate = candidate
    }

    init(
        archiveFormatVersion: Int,
        archiveSchemaVersion: Int32,
        current: BookSummary,
        candidate: BookSummary
    ) {
        self.init(
            archiveFormatVersion: archiveFormatVersion,
            archiveSchemaVersion: archiveSchemaVersion,
            current: .available(current),
            candidate: candidate
        )
    }
}

/// Confirmation authority for one exact staged ciphertext. The URL and full
/// digest stay internal to the restore boundary and are never rendered.
struct RestorePreviewTicket: Identifiable, Sendable {
    let id: UUID
    let preview: RestorePreview
    let stagedArchiveURL: URL
    let archiveFingerprint: RestoreArchiveFingerprint

    init(
        preview: RestorePreview,
        stagedArchiveURL: URL,
        archiveFingerprint: RestoreArchiveFingerprint
    ) {
        id = UUID()
        self.preview = preview
        self.stagedArchiveURL = stagedArchiveURL
        self.archiveFingerprint = archiveFingerprint
    }

    /// Confirming this preview keeps exactly the damaged rows it showed.
    var damagePolicy: RestoreDamagePolicy {
        RestoreDamagePolicy(confirmedCount: preview.candidate.quarantinedRecordCount)
    }
}

/// What a restore does with rows the normal recovering open sets aside: rows
/// in a collection it reads with recovery that fail their domain decode or
/// carry a non-canonical key. Backups keep those rows byte for byte, so a
/// restore either refuses them or, once confirmed, keeps them set aside just
/// as the source book did. Envelope, size and work limits never relax.
enum RestoreDamagePolicy: Equatable, Sendable {
    /// All or nothing: one damaged row rejects the archive.
    case reject
    /// Preview: set damaged rows aside and report how many.
    case report
    /// Commit of a confirmed preview: require exactly the count it showed.
    case confirmed(Int)

    /// A ticket authorizes setting rows aside only when its preview showed some.
    init(confirmedCount: Int) {
        self = confirmedCount > 0 ? .confirmed(confirmedCount) : .reject
    }

    var confirmedCount: Int {
        guard case let .confirmed(count) = self else { return 0 }
        return count
    }

    func setsAside(_ collection: RecordCollection, recordID: String) -> Bool {
        guard self != .reject else { return false }
        switch collection {
        case .accounts, .journalEntries, .budgetNodes, .scheduledTransactions,
             .investmentHoldings, .netWorthSnapshots, .quickLogDrafts,
             .receiptAttachments, .exchangeRates, .savingsGoals, .loanPlans,
             .allowancePlans, .budgetEntryAttributions:
            return true
        case .budgetConfigurationTimelines:
            return recordID == BudgetConfigurationTimeline.primaryRecordID
        case .profile, .journalEntryRevisions, .cloudBackupIdentity,
             .pendingLockedCaptures, .accountLifecycleAudit:
            return false
        }
    }

    /// The set-aside count a validated book may publish. Every row the raw
    /// gate let through must be one the recovering open reported.
    func verifiedSetAsideCount(
        exemptedRowCount: Int,
        recoveryIssueCount: Int
    ) throws -> Int {
        guard exemptedRowCount == 0 || recoveryIssueCount > 0 else {
            throw AppModelError.invalidBook
        }
        switch self {
        case .reject:
            guard recoveryIssueCount == 0 else { throw AppModelError.invalidBook }
        case .report:
            break
        case let .confirmed(count):
            guard recoveryIssueCount == count else {
                throw AppModelError.restorePreviewChanged
            }
        }
        return recoveryIssueCount
    }
}

struct RestoreArchiveFingerprint: Equatable, Sendable {
    let byteCount: Int
    let sha256: Data
}

struct RestoreCandidatePreviewValidation: Sendable {
    let archiveMetadata: PortableArchiveRestoreMetadata
    let countSnapshot: DatabaseRecordCountSnapshot
    let entryMetadata: RestoreEntryPreviewMetadata
    let currencies: [CurrencyCode]
    let quarantinedRecordCount: Int
    let reportingTimeZoneIdentifier: String
}
