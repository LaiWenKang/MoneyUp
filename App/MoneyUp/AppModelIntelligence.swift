import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import MoneyUpPersistence

/// A zero review count is publishable only after intelligence finishes for the
/// exact logical-book revision. A single holder keeps this race state out of
/// the already-large AppModel declaration.
struct WidgetIntelligencePublicationState {
    var task: Task<Void, Never>?
    var revision: UInt64 = 0
    var resultsAreCurrent = false
}

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
        invalidateWidgetIntelligencePublication()
        guard !isBookReplacementInProgress,
              state == .ready,
              let profile,
              let store,
              profile.intelligenceEnabled else {
            intelligenceService.cancelPendingWork()
            if state == .ready, self.profile != nil {
                refreshBudgetWidgetSnapshot()
            }
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
            refreshBudgetWidgetSnapshot()
            return
        }
        intelligenceService.refresh(
            store: store,
            originDayKeyRange: startDay...asOfDay,
            asOfDay: asOfDay,
            enabled: true
        )
        // Clear any prior generation immediately. A nil review count means
        // "refreshing/unavailable"; it must never masquerade as a valid zero.
        refreshBudgetWidgetSnapshot()

        let publicationRevision = widgetIntelligencePublication.revision
        let generation = storeGeneration
        let refreshInvocation = intelligenceService.refreshInvocationCount
        let cancelInvocation = intelligenceService.cancelInvocationCount
        widgetIntelligencePublication.task = Task { [weak self] in
            guard let self else { return }
            await self.intelligenceService.waitForCurrentRefresh()
            guard !Task.isCancelled,
                  publicationRevision == self.widgetIntelligencePublication.revision,
                  refreshInvocation == self.intelligenceService.refreshInvocationCount,
                  cancelInvocation == self.intelligenceService.cancelInvocationCount,
                  self.isCurrentStoreGeneration(generation),
                  self.state == .ready,
                  self.profile?.intelligenceEnabled == true,
                  !self.intelligenceService.isRefreshing else { return }
            self.widgetIntelligencePublication.task = nil
            self.widgetIntelligencePublication.resultsAreCurrent =
                !self.intelligenceService.isUnavailable
            self.refreshBudgetWidgetSnapshot()
        }
    }

    func waitForCurrentIntelligenceRefresh() async {
        await intelligenceService.waitForCurrentRefresh()
        await widgetIntelligencePublication.task?.value
    }

    /// Invalidates only the derivative publication. The intelligence service
    /// owns its own task cancellation/revision and may continue until the next
    /// refresh replaces it.
    func invalidateWidgetIntelligencePublication() {
        widgetIntelligencePublication.revision &+= 1
        widgetIntelligencePublication.resultsAreCurrent = false
        widgetIntelligencePublication.task?.cancel()
        widgetIntelligencePublication.task = nil
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
              !isBookReplacementInProgress,
              profile?.intelligenceEnabled == true,
              let read = try? beginLogicalBookRead() else { return empty }
        let suggestionStore = read.store
        do {
            let candidates = try await suggestionStore.payeeAffinityCandidates(
                payee: query.payee,
                currency: query.currency
            )
            try requireLogicalBookRead(read.token)
            guard let ranked = PayeeAffinityRanker.suggestion(
                      from: candidates,
                      currency: query.currency,
                      eligibleCategoryIDs: eligibleCategoryIDs
                  ),
                  let mostRecentUse = date(
                      fromIntelligenceDay: ranked.lastOccurrenceDay
                  ) else {
                return try await finishLogicalBookRead(
                    empty,
                    token: read.token
                )
            }
            let evidence = CaptureSuggestionEvidence(
                supportingEntryCount: ranked.supportingEntryCount,
                eligibleEntryCount: ranked.eligibleEntryCount,
                exactPayeeEntryCount: ranked.supportingEntryCount,
                mostRecentUse: mostRecentUse,
                usedPayeeHistory: true
            )
            let result = CaptureSuggestionResult(
                queryFingerprint: query.fingerprint,
                accountSuggestion: nil,
                categorySuggestion: CaptureFieldSuggestion(
                    ledgerAccountID: ranked.categoryID,
                    confidence: ranked.confidence,
                    evidence: evidence
                )
            )
            return try await finishLogicalBookRead(result, token: read.token)
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
        let read = try beginLogicalBookRead()
        let historyStore = read.store
        var result: [JournalEntry] = []
        result.reserveCapacity(entryIDs.count)
        for id in entryIDs where !invalidJournalEntryIDs.contains(id) {
            try Task.checkCancellation()
            if let entry = try await historyStore.fetch(
                JournalEntry.self,
                id: id.uuidString,
                from: .journalEntries
            ) {
                try requireLogicalBookRead(read.token)
                result.append(entry)
            } else {
                try requireLogicalBookRead(read.token)
            }
        }
        return try await finishLogicalBookRead(
            result.sorted { $0.occurredAt > $1.occurredAt },
            token: read.token
        )
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
