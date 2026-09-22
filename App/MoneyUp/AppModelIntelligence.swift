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

    /// Findings that still need the user's attention: not already covered by
    /// a schedule and not explicitly marked as reviewed.
    var intelligenceFindings: [IntelligenceFinding] {
        let reviewed = reviewedIntelligenceFindingIDs
        return intelligenceService.findings.filter {
            !Self.isReviewed($0, in: reviewed) && !isCoveredByExistingSchedule($0)
        }
    }

    /// Current findings the user has already reviewed. They stay available so
    /// a dismissal can be undone; they never count toward attention badges.
    var reviewedIntelligenceFindings: [IntelligenceFinding] {
        let reviewed = reviewedIntelligenceFindingIDs
        guard !reviewed.isEmpty else { return [] }
        return intelligenceService.findings.filter {
            Self.isReviewed($0, in: reviewed) && !isCoveredByExistingSchedule($0)
        }
    }

    var reviewedIntelligenceFindingIDs: Set<String> {
        Set(profile?.reviewedIntelligenceFindingIDs ?? [])
    }

    func isIntelligenceFindingReviewed(_ id: String) -> Bool {
        let reviewed = reviewedIntelligenceFindingIDs
        guard let finding = intelligenceService.findings.first(where: { $0.id == id }) else {
            return reviewed.contains(id)
        }
        return Self.isReviewed(finding, in: reviewed)
    }

    private static func isReviewed(_ finding: IntelligenceFinding, in reviewed: Set<String>) -> Bool {
        reviewed.contains(intelligenceReviewKey(for: finding)) || reviewed.contains(finding.id)
    }

    /// What "reviewed" attaches to. Detector identifiers for a recurring
    /// series are keyed on the newest occurrence, so the same subscription
    /// would resurface as a "new" finding every time it was paid. Reviewing a
    /// series therefore keys on the series itself; a price increase also keys
    /// on the stepped amount so a further increase is shown again. Duplicate
    /// and anomaly findings are already stable per entry.
    static func intelligenceReviewKey(for finding: IntelligenceFinding) -> String {
        switch (finding.kind, finding.route) {
        case let (.recurrence, .scheduleOffer(offer)):
            return "series:recurrence:\(offer.kind):\(offer.accountID.uuidString.lowercased()):"
                + "\(offer.categoryID.uuidString.lowercased()):\(offer.payeeKey)"
        case let (.lapsedSubscription, .history(entryIDs, _)):
            guard let first = entryIDs.first else { return finding.id }
            return "series:lapsed:\(first.uuidString.lowercased())"
        case let (.priceIncrease, .history(entryIDs, _)):
            guard let first = entryIDs.first else { return finding.id }
            var key = "series:price:\(first.uuidString.lowercased())"
            if let latest = finding.figures.first(where: { $0.labelKey == "intelligence.figure.latest" }),
               case let .money(money) = latest.value {
                key += ":\(money.amount):\(money.currency.value)"
            }
            return key
        default:
            return finding.id
        }
    }

    private func reviewKey(forFindingID id: String) -> String {
        intelligenceService.findings.first { $0.id == id }
            .map(Self.intelligenceReviewKey(for:)) ?? id
    }

    /// Hides one finding after the user has looked at it. The stored key is
    /// stable across refreshes, relaunches and backups of this book.
    func markIntelligenceFindingReviewed(_ id: String) async throws {
        guard state == .ready, profile != nil else { throw AppModelError.missingRecord }
        guard !isIntelligenceFindingReviewed(id) else { return }
        let key = reviewKey(forFindingID: id)
        try await mutateProfile { profile in
            profile.reviewedIntelligenceFindingIDs = UserProfile.normalizedReviewedFindingIDs(
                profile.reviewedIntelligenceFindingIDs + [key]
            )
        }
        refreshBudgetWidgetSnapshot()
    }

    /// Brings a reviewed finding back to the attention list.
    func restoreIntelligenceFinding(_ id: String) async throws {
        guard state == .ready, profile != nil else { throw AppModelError.missingRecord }
        guard isIntelligenceFindingReviewed(id) else { return }
        let key = reviewKey(forFindingID: id)
        try await mutateProfile { profile in
            profile.reviewedIntelligenceFindingIDs.removeAll { $0 == id || $0 == key }
        }
        refreshBudgetWidgetSnapshot()
    }

    /// Marks every currently visible finding as reviewed in one profile write.
    func markAllIntelligenceFindingsReviewed() async throws {
        guard state == .ready, profile != nil else { throw AppModelError.missingRecord }
        let keys = intelligenceFindings.map(Self.intelligenceReviewKey(for:))
        guard !keys.isEmpty else { return }
        try await mutateProfile { profile in
            profile.reviewedIntelligenceFindingIDs = UserProfile.normalizedReviewedFindingIDs(
                profile.reviewedIntelligenceFindingIDs + keys
            )
        }
        refreshBudgetWidgetSnapshot()
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
              profile?.merchantSuggestionsEnabled != false,
              let read = try? beginLogicalBookRead() else { return empty }
        let suggestionStore = read.store
        do {
            let candidates = try await suggestionStore.payeeAffinityCandidates(
                payee: query.payee,
                currency: query.currency
            )
            try requireLogicalBookRead(read.token)
            guard profile?.merchantSuggestionsEnabled != false else {
                return try await finishLogicalBookRead(empty, token: read.token)
            }
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


extension AppModel {
    func historyPreloadSuggestions(for query: CaptureSuggestionQuery,
                                   eligibleCategoryIDs: Set<UUID>, accountID: UUID? = nil,
                                   categoryID: UUID? = nil,
                                   eligibleAccountIDs: Set<UUID>? = nil) async -> (
        fields: CaptureSuggestionResult, merchants: [HistoryPreloadSuggestion]
    ) {
        let empty = (fields: CaptureSuggestionResult(queryFingerprint: query.fingerprint,
            accountSuggestion: nil, categorySuggestion: nil), merchants: [HistoryPreloadSuggestion]())
        guard state == .ready, profile?.intelligenceEnabled == true,
              profile?.merchantSuggestionsEnabled != false,
              !isBookReplacementInProgress,
              let read = try? beginLogicalBookRead() else { return empty }
        let choiceIDs = eligibleAccountIDs ?? Set(LedgerEntryChoices.visible(accounts,
            preserving: Set([accountID].compactMap { $0 })).map(\.id))
        let eligibleAccounts = accounts.filter {
            if $0.kind == .expense || $0.kind == .income { return eligibleCategoryIDs.contains($0.id) }
            return choiceIDs.contains($0.id)
        }
        let revision = journalProjectionRevision
        let calendar = reportingCalendar
        do {
            let page = try await read.store.fetchJournalEntryPage(
                startDate: query.occurredAt.addingTimeInterval(-180 * 86_400),
                endDateExclusive: Date(timeIntervalSinceReferenceDate:
                    query.occurredAt.timeIntervalSinceReferenceDate.nextUp), limit: 200)
            try requireLogicalBookRead(read.token)
            guard revision == journalProjectionRevision,
                  profile?.intelligenceEnabled == true,
                  profile?.merchantSuggestionsEnabled != false,
                  page.issues.isEmpty else { return try await finishLogicalBookRead(empty, token: read.token) }
            let result = await Task.detached(priority: .utility) {
                (fields: CaptureSuggestionEngine.suggestions(for: query, entries: page.entries,
                    accounts: eligibleAccounts),
                 merchants: HistoryPreload.suggestions(for: query, entries: page.entries,
                    accounts: eligibleAccounts, calendar: calendar,
                    accountID: accountID, categoryID: categoryID))
            }.value
            let current = try await finishLogicalBookRead(result, token: read.token)
            guard revision == journalProjectionRevision else { return empty }
            return current
        } catch { return empty }
    }
}
