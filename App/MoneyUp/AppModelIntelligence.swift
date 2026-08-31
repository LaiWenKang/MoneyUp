import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import MoneyUpPersistence

extension AppModel {
    var intelligenceFindings: [IntelligenceFinding] {
        intelligenceService.findings
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
