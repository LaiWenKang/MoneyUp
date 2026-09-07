import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct CaptureDuplicateReview: Sendable {
    let queryFingerprint: String
    let match: CaptureDuplicateMatch
    let historyDate: Date
    let projectionRevision: UInt64
}

extension AppModel {
    /// Search the complete indexed time window, independent of the recent UI
    /// cache. Only a bounded page and the strongest candidate remain in memory.
    func captureDuplicateReview(for query: CaptureDuplicateQuery) async throws -> CaptureDuplicateReview? {
        let read = try beginLogicalBookRead()
        let reviewStore = read.store
        let revision = journalProjectionRevision
        let excludedIDs = invalidJournalEntryIDs
        let calendar = reportingCalendar
        let worker = Task.detached(priority: .userInitiated) {
            try await CaptureDuplicateReviewReader.read(
                query: query, store: reviewStore, excluding: excludedIDs,
                calendar: calendar, projectionRevision: revision
            )
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        let current = try await finishLogicalBookRead(result, token: read.token)
        guard revision == journalProjectionRevision else { throw CancellationError() }
        return current
    }
}

private enum CaptureDuplicateReviewReader {
    static func read(
        query: CaptureDuplicateQuery, store: EncryptedRecordStore,
        excluding excludedIDs: Set<UUID>, calendar: Calendar,
        projectionRevision: UInt64
    ) async throws -> CaptureDuplicateReview? {
        let window = CaptureDuplicateDetector.defaultMaximumTimeInterval
        let start = query.occurredAt.addingTimeInterval(-window)
        // The detector's upper bound is inclusive. Advance one representable
        // Unix timestamp so the storage half-open bound retains that endpoint.
        let end = Date(timeIntervalSince1970:
            query.occurredAt.addingTimeInterval(window).timeIntervalSince1970.nextUp)
        var best: (match: CaptureDuplicateMatch, entry: JournalEntry)?
        // Source-identified replay can be older than the ordinary time window.
        // Both reads use existing indexes; source-system/movement still pass
        // the same domain detector before a match can be shown.
        let sources: [String?] = [nil] + (query.sourceReference.map { [$0.fingerprint] } ?? [])
        for source in sources {
            var cursor: JournalEntryPageCursor?
            repeat {
                try Task.checkCancellation()
                let page = try await store.fetchJournalEntryPage(
                    startDate: source == nil ? start : nil,
                    endDateExclusive: source == nil ? end : nil,
                    sourceFingerprint: source, after: cursor, limit: 200
                )
                guard page.issues.allSatisfy({ issue in
                    UUID(uuidString: issue.recordID).map { excludedIDs.contains($0) } ?? false
                }) else { throw AppModelError.invalidBook }
                let entries = page.entries.filter { !excludedIDs.contains($0.id) }
                let candidates = CaptureDuplicateDetector.matches(for: query, in: entries)
                if let candidate = candidates.matches.first,
                   let entry = entries.first(where: { $0.id == candidate.entryID }),
                   best.map({ precedes(candidate, $0.match) }) ?? true {
                    best = (candidate, entry)
                }
                cursor = page.nextCursor
            } while cursor != nil
        }
        try Task.checkCancellation()
        return best.map {
            CaptureDuplicateReview(
                queryFingerprint: query.fingerprint, match: $0.match,
                historyDate: $0.entry.originContext.attributedDate(in: calendar) ?? $0.entry.occurredAt,
                projectionRevision: projectionRevision
            )
        }
    }

    private static func precedes(_ lhs: CaptureDuplicateMatch, _ rhs: CaptureDuplicateMatch) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.evidence.timeDifference != rhs.evidence.timeDifference {
            return lhs.evidence.timeDifference < rhs.evidence.timeDifference
        }
        return lhs.entryID.uuidString < rhs.entryID.uuidString
    }
}
