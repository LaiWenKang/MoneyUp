import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import MoneyUpPersistence

extension AppModel {
    static let maximumIntelligenceHistoryReviewCount = 100

    var intelligenceFindings: [IntelligenceFinding] {
        intelligenceService.findings.filter { !isCoveredByExistingSchedule($0) }
    }

    var isIntelligenceRefreshing: Bool {
        intelligenceService.isRefreshing
    }

    var intelligenceIsUnavailable: Bool {
        intelligenceService.isUnavailable
    }

    var intelligenceResultsAreLimited: Bool {
        intelligenceService.resultsAreLimited
    }

    private func isCoveredByExistingSchedule(
        _ finding: IntelligenceFinding
    ) -> Bool {
        guard case let .scheduleOffer(offer) = finding.route else { return false }
        return scheduledTransactions.contains { schedule in
            schedule.status == .active
                && schedule.kind == offer.kind
                && schedule.accountID == offer.accountID
                && schedule.categoryAccountID == offer.categoryID
                && schedule.frequency == offer.frequency
                && schedule.amount == offer.amount
        }
    }

    func refreshIntelligence() {
        guard state == .ready,
              let profile,
              let store,
              profile.intelligenceEnabled else {
            intelligenceService.cancelPendingWork()
            return
        }
        let asOfDay = FinancialPeriodBoundary.dayKey(
            for: currentDate(),
            calendar: reportingCalendar
        )
        guard let startDay = try? IntelligenceDay.adding(
            days: -1_829,
            to: asOfDay
        ) else {
            intelligenceService.cancelPendingWork()
            return
        }
        intelligenceService.refresh(
            store: store,
            originDayKeyRange: startDay...asOfDay,
            asOfDay: asOfDay,
            enabled: true
        )
    }

    func waitForCurrentIntelligenceRefresh() async {
        await intelligenceService.waitForCurrentRefresh()
    }

    func indexedCaptureSuggestion(
        for query: CaptureSuggestionQuery,
        eligibleCategoryIDs: Set<UUID>
    ) async -> CaptureSuggestionResult {
        let empty = CaptureSuggestionResult(
            queryFingerprint: query.fingerprint,
            accountSuggestion: nil,
            categorySuggestion: nil
        )
        guard state == .ready,
              profile?.intelligenceEnabled == true,
              let suggestionStore = store else { return empty }
        let generation = storeGeneration
        do {
            let candidates = try await suggestionStore.payeeAffinityCandidates(
                payee: query.payee,
                currency: query.currency
            )
            guard ownsStoreGeneration(generation),
                  let ranked = PayeeAffinityRanker.suggestion(
                      from: candidates,
                      currency: query.currency,
                      eligibleCategoryIDs: eligibleCategoryIDs
                  ),
                  let mostRecentUse = date(
                      fromIntelligenceDay: ranked.lastOccurrenceDay
                  ) else { return empty }
            let evidence = CaptureSuggestionEvidence(
                supportingEntryCount: ranked.supportingEntryCount,
                eligibleEntryCount: ranked.eligibleEntryCount,
                exactPayeeEntryCount: ranked.supportingEntryCount,
                mostRecentUse: mostRecentUse,
                usedPayeeHistory: true
            )
            return CaptureSuggestionResult(
                queryFingerprint: query.fingerprint,
                accountSuggestion: nil,
                categorySuggestion: CaptureFieldSuggestion(
                    ledgerAccountID: ranked.categoryID,
                    confidence: ranked.confidence,
                    evidence: evidence
                )
            )
        } catch {
            return empty
        }
    }

    /// User-directed evidence review may decode only the exact requested rows.
    /// Routine detection and Quick Log suggestions remain normalized-index only.
    func intelligenceHistoryEntries(
        entryIDs: [UUID]
    ) async throws -> [JournalEntry] {
        guard !entryIDs.isEmpty,
              entryIDs.count <= Self.maximumIntelligenceHistoryReviewCount else {
            throw AppModelError.invalidBook
        }
        let generation = storeGeneration
        let historyStore = try requireStore()
        var result: [JournalEntry] = []
        result.reserveCapacity(entryIDs.count)
        for id in entryIDs where !invalidJournalEntryIDs.contains(id) {
            try Task.checkCancellation()
            if let entry = try await historyStore.fetch(
                JournalEntry.self,
                id: id.uuidString,
                from: .journalEntries
            ) {
                result.append(entry)
            }
        }
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        return result.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func date(fromIntelligenceDay value: Int) -> Date? {
        let year = value / 10_000
        let month = value / 100 % 100
        let day = value % 100
        let components = DateComponents(
            calendar: reportingCalendar,
            timeZone: reportingCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )
        guard let date = reportingCalendar.date(from: components),
              FinancialPeriodBoundary.dayKey(
                  for: date,
                  calendar: reportingCalendar
              ) == value else { return nil }
        return date
    }
}
