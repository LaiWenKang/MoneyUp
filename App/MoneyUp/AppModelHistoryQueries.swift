import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func historyPage(
        query: HistoryQuery,
        after cursor: JournalEntryPageCursor? = nil,
        limit: Int = 80
    ) async throws -> HistoryPageResult {
        let read = try beginLogicalBookRead()
        let historyStore = read.store
        let accountSnapshot = accounts
        let calendarSnapshot = reportingCalendar
        let dayKeys = historyDayKeys(for: query, calendar: calendarSnapshot)
        let validAccountIDs = Set(accountSnapshot.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs
        let boundedLimit = min(max(limit, 1), 200)
        let scanLimit = min(max(boundedLimit * 2, 160), 500)
        var scanCursor = cursor
        var matches: [JournalEntry] = []

        while matches.count < boundedLimit {
            try Task.checkCancellation()
            let rawPage = try await historyStore.fetchJournalEntryPage(
                startDayKey: dayKeys.start,
                endDayKeyExclusive: dayKeys.endExclusive,
                after: scanCursor,
                limit: scanLimit
            )
            try requireLogicalBookRead(read.token)
            recordHistoryDecodeIssues(rawPage.issues)
            let relationshipIssues = rawPage.entries.filter { entry in
                entry.postings.contains { !validAccountIDs.contains($0.accountID) }
            }.map {
                RecordDecodeIssue(
                    collection: .journalEntries,
                    recordID: $0.id.uuidString
                )
            }
            recordHistoryDecodeIssues(relationshipIssues)
            let filtered = await Task.detached(priority: .userInitiated) {
                query.filteredEntries(
                    rawPage.entries.filter { entry in
                        !quarantinedEntryIDs.contains(entry.id)
                            && entry.postings.allSatisfy {
                            validAccountIDs.contains($0.accountID)
                        }
                    },
                    accounts: accountSnapshot,
                    calendar: calendarSnapshot
                )
            }.value
            try requireLogicalBookRead(read.token)
            let remaining = boundedLimit - matches.count
            matches.append(contentsOf: filtered.prefix(remaining))

            if filtered.count >= remaining {
                let moreResultsMayExist = filtered.count > remaining
                    || rawPage.nextCursor != nil
                return try await finishLogicalBookRead(
                    HistoryPageResult(
                        entries: matches,
                        nextCursor: moreResultsMayExist
                            ? historyCursor(for: matches.last)
                            : nil
                    ),
                    token: read.token
                )
            }
            guard let nextCursor = rawPage.nextCursor else {
                return try await finishLogicalBookRead(
                    HistoryPageResult(entries: matches, nextCursor: nil),
                    token: read.token
                )
            }
            scanCursor = nextCursor
        }

        return try await finishLogicalBookRead(
            HistoryPageResult(
                entries: matches,
                nextCursor: historyCursor(for: matches.last)
            ),
            token: read.token
        )
    }

    private func historyCursor(
        for entry: JournalEntry?
    ) -> JournalEntryPageCursor? {
        entry.map {
            JournalEntryPageCursor(
                occurredAt: $0.occurredAt,
                recordID: $0.id.uuidString
            )
        }
    }

    private func historyDayKeys(
        for query: HistoryQuery,
        calendar: Calendar
    ) -> (start: Int?, endExclusive: Int?) {
        let start = query.startDate.flatMap {
            FinancialPeriodBoundary.lowerDayKey(
                forStartDate: $0,
                calendar: calendar
            )
        }
        let endExclusive = query.endDateExclusive.flatMap {
            FinancialPeriodBoundary.upperDayKeyExclusive(
                forEndDateExclusive: $0,
                calendar: calendar
            )
        }
        return (start, endExclusive)
    }

    /// Calculates the complete running total from bounded indexed pages. No
    /// full-journal filter runs on the main thread and no decoded result set is
    /// retained after the summary is returned.
    func historySummary(query: HistoryQuery) async throws -> HistorySummary {
        let read = try beginLogicalBookRead()
        let historyStore = read.store
        let accountSnapshot = accounts
        let calendarSnapshot = reportingCalendar
        let startDayKey = query.startDate.flatMap {
            FinancialPeriodBoundary.lowerDayKey(
                forStartDate: $0,
                calendar: calendarSnapshot
            )
        }
        let endDayKeyExclusive = query.endDateExclusive.flatMap {
            FinancialPeriodBoundary.upperDayKeyExclusive(
                forEndDateExclusive: $0,
                calendar: calendarSnapshot
            )
        }
        let validAccountIDs = Set(accountSnapshot.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs
        var cursor: JournalEntryPageCursor?
        var transactionCount = 0
        var amountsByCurrency: [CurrencyCode: Decimal] = [:]

        repeat {
            try Task.checkCancellation()
            let rawPage = try await historyStore.fetchJournalEntryPage(
                startDayKey: startDayKey,
                endDayKeyExclusive: endDayKeyExclusive,
                after: cursor,
                limit: 500
            )
            try requireLogicalBookRead(read.token)
            recordHistoryDecodeIssues(rawPage.issues)
            let relationshipIssues = rawPage.entries.filter { entry in
                entry.postings.contains { !validAccountIDs.contains($0.accountID) }
            }.map {
                RecordDecodeIssue(
                    collection: .journalEntries,
                    recordID: $0.id.uuidString
                )
            }
            recordHistoryDecodeIssues(relationshipIssues)
            let pageSummary = try await Task.detached(priority: .userInitiated) {
                let filtered = query.filteredEntries(
                    rawPage.entries.filter { entry in
                        !quarantinedEntryIDs.contains(entry.id)
                            && entry.postings.allSatisfy {
                            validAccountIDs.contains($0.accountID)
                        }
                    },
                    accounts: accountSnapshot,
                    calendar: calendarSnapshot
                )
                return try HistoryQuery().summary(
                    for: filtered,
                    accounts: accountSnapshot
                )
            }.value
            try requireLogicalBookRead(read.token)
            transactionCount += pageSummary.transactionCount
            for (currency, amount) in pageSummary.amountsByCurrency {
                amountsByCurrency[currency] = try CheckedDecimal.adding(
                    amountsByCurrency[currency] ?? .zero,
                    amount
                )
            }
            cursor = rawPage.nextCursor
        } while cursor != nil

        return try await finishLogicalBookRead(
            HistorySummary(
                transactionCount: transactionCount,
                amountsByCurrency: amountsByCurrency
            ),
            token: read.token
        )
    }

    /// Loads actuals for one visible Calendar range from the chronological
    /// SQLCipher index. The result is never merged into the recent cache and a
    /// date change can cancel the caller's task without leaving partial state.
    func calendarEntries(in interval: DateInterval) async throws -> [JournalEntry] {
        let read = try beginLogicalBookRead()
        guard let dayKeys = FinancialPeriodBoundary.dayKeyRange(
            for: interval,
            calendar: reportingCalendar
        ) else { throw AppModelError.invalidBook }
        let entries = try await journalEntries(
            startDayKey: dayKeys.lowerBound,
            endDayKeyExclusive: dayKeys.upperBound
        )
        return try await finishLogicalBookRead(entries, token: read.token)
    }

    /// Complete normalized posting events for a bounded derived-data horizon.
    /// Budget rollover/snapshot preparation must use this hook (extending the
    /// interval to its earliest active rollover) rather than the 80-entry
    /// recent-activity cache.
    func journalPostingEvents(
        in interval: DateInterval
    ) async throws -> [LedgerPostingEvent] {
        let read = try beginLogicalBookRead()
        let eventStore = read.store
        guard let dayKeys = FinancialPeriodBoundary.dayKeyRange(
            for: interval,
            calendar: reportingCalendar
        ) else { throw AppModelError.invalidBook }
        let events = try await eventStore.fetchJournalPostingEvents(
            originDayKeyRange: dayKeys,
            excludingEntryIDs: invalidJournalEntryIDs
        )
        try requireLogicalBookRead(read.token)
        return try await finishLogicalBookRead(events, token: read.token)
    }

    /// Schedule matching remains exact while bounding the candidate read to a
    /// useful window around the occurrence instead of scanning the journal.
    func matchingEntries(
        for schedule: ScheduledTransaction,
        calendar: Calendar? = nil
    ) async throws -> [JournalEntry] {
        let read = try beginLogicalBookRead()
        let matchCalendar = calendar ?? reportingCalendar
        guard let start = matchCalendar.date(
            byAdding: .day,
            value: -31,
            to: schedule.nextOccurrence
        ), let end = matchCalendar.date(
            byAdding: .day,
            value: 32,
            to: schedule.nextOccurrence
        ) else { throw AppModelError.invalidBook }
        let linkedIDs = Set(
            scheduledTransactions.flatMap(\.resolutions).compactMap(\.linkedEntryID)
        )
        let candidateInterval = DateInterval(start: start, end: end)
        guard let dayKeys = FinancialPeriodBoundary.dayKeyRange(
            for: candidateInterval,
            calendar: matchCalendar
        ) else { throw AppModelError.invalidBook }
        let candidates = try await journalEntries(
            startDayKey: dayKeys.lowerBound,
            endDayKeyExclusive: dayKeys.upperBound
        )
        let matches = candidates.filter {
            !linkedIDs.contains($0.id) && schedule.matches($0)
        }
        return try await finishLogicalBookRead(matches, token: read.token)
    }

    func journalEntries(
        startDate: Date? = nil,
        endDateExclusive: Date? = nil,
        startDayKey: Int? = nil,
        endDayKeyExclusive: Int? = nil,
        includeInvalidRelationships: Bool = false
    ) async throws -> [JournalEntry] {
        let read = try beginLogicalBookRead()
        let journalStore = read.store
        let validAccountIDs = Set(accounts.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs
        var cursor: JournalEntryPageCursor?
        var result: [JournalEntry] = []
        repeat {
            try Task.checkCancellation()
            let page = try await journalStore.fetchJournalEntryPage(
                startDate: startDate,
                endDateExclusive: endDateExclusive,
                startDayKey: startDayKey,
                endDayKeyExclusive: endDayKeyExclusive,
                after: cursor,
                limit: 500
            )
            try requireLogicalBookRead(read.token)
            recordHistoryDecodeIssues(page.issues)
            for entry in page.entries {
                guard !quarantinedEntryIDs.contains(entry.id) else { continue }
                let relationshipsAreValid = entry.postings.allSatisfy {
                    validAccountIDs.contains($0.accountID)
                }
                if relationshipsAreValid || includeInvalidRelationships {
                    result.append(entry)
                }
                if !relationshipsAreValid {
                    recordHistoryDecodeIssues([
                        RecordDecodeIssue(
                            collection: .journalEntries,
                            recordID: entry.id.uuidString
                        )
                    ])
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        return try await finishLogicalBookRead(result, token: read.token)
    }

    /// Explicit export/import/lifecycle operations need one coherent journal
    /// snapshot. SQLCipher returns it from a single actor-isolated SELECT; the
    /// temporary decoded array is released when the operation completes and is
    /// never assigned to the production recent cache.
    func journalSnapshot(
        includeInvalidRelationships: Bool
    ) async throws -> [JournalEntry] {
        let read = try beginLogicalBookRead()
        let snapshotStore = read.store
        let recovered = try await snapshotStore.fetchAllIdentifiedRecovering(
            JournalEntry.self,
            from: .journalEntries
        )
        try requireLogicalBookRead(read.token)
        recordHistoryDecodeIssues(recovered.issues)
        let validAccountIDs = Set(accounts.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs.union(
            recovered.issues.compactMap { UUID(uuidString: $0.recordID) }
        )
        let entries = recovered.values.filter { entry in
            guard !quarantinedEntryIDs.contains(entry.id) else { return false }
            let valid = entry.postings.allSatisfy {
                validAccountIDs.contains($0.accountID)
            }
            if !valid {
                recordHistoryDecodeIssues([
                    RecordDecodeIssue(
                        collection: .journalEntries,
                        recordID: entry.id.uuidString
                    )
                ])
            }
            return valid || includeInvalidRelationships
        }
        return try await finishLogicalBookRead(entries, token: read.token)
    }

    func recordHistoryDecodeIssues(_ issues: [RecordDecodeIssue]) {
        guard !issues.isEmpty else { return }
        var known = Set(recoveryIssues)
        recoveryIssues.append(contentsOf: issues.compactMap { issue in
            let identifier = "\(issue.collection.rawValue)/\(issue.recordID)"
            return known.insert(identifier).inserted ? identifier : nil
        })
    }

    /// Keeps the latest form state in memory immediately, then serializes a
    /// debounced copy into SQLCipher. Background locking cancels the debounce
    /// and flushes this latest snapshot before closing the store.
}
