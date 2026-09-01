import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import MoneyUpPersistence

struct BudgetSuggestionPatch: Sendable {
    let before: [BudgetNode]
    let after: [BudgetNode]
}

extension AppModel {
    func budgetLimitSuggestionsResult(
        asOf requestedDate: Date? = nil
    ) async -> DerivedValue<[BudgetLimitSuggestion]> {
        guard state == .ready,
              profile?.intelligenceEnabled == true else {
            return .unavailable(.intelligenceBudgetUnavailable)
        }
        let asOf = requestedDate ?? currentDate()
        do {
            let context = try budgetSuggestionContext(asOf: asOf)
            let events = try await journalPostingEvents(in: context.interval)
            let histories = try categoryLimitHistories(
                events: events,
                context: context
            )
            let suggestions = try BudgetSuggestionEngine.suggestions(
                from: histories
            ).filter { $0.proposedLimit.amount > .zero }
            return .available(suggestions)
        } catch {
            DerivedValueDiagnostics.record(
                .intelligenceBudgetUnavailable,
                operation: "intelligence-budget-suggestions",
                error: error
            )
            return .unavailable(.intelligenceBudgetUnavailable)
        }
    }

    func applyBudgetSuggestions(
        _ suggestions: [BudgetLimitSuggestion]
    ) async throws -> BudgetSuggestionPatch {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let update = try budgetSuggestionUpdate(suggestions)
        let timeline = try budgetConfigurationTimelineRecording(nodes: update.nodes)
        try await persistBudgetSuggestionNodes(
            update.changedAfter,
            timeline: timeline
        )
        budgetConfigurationTimeline = timeline
        budgetNodes = update.nodes
        return BudgetSuggestionPatch(
            before: update.changedBefore,
            after: update.changedAfter
        )
    }

    func undoBudgetSuggestionPatch(
        _ patch: BudgetSuggestionPatch
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let restored = try budgetNodesRestoring(patch)
        let timeline = try budgetConfigurationTimelineRecording(nodes: restored)
        try await persistBudgetSuggestionNodes(
            patch.before,
            timeline: timeline
        )
        budgetConfigurationTimeline = timeline
        budgetNodes = restored
    }

    private func budgetSuggestionContext(
        asOf: Date
    ) throws -> BudgetSuggestionContext {
        let calendar = reportingCalendar
        guard let currentMonth = calendar.dateInterval(of: .month, for: asOf),
              let firstStart = calendar.date(
                  byAdding: .month,
                  value: -BudgetSuggestionEngine.maximumTrailingMonthCount,
                  to: currentMonth.start
              ) else { throw AppModelError.invalidBook }
        var months: [DateInterval] = []
        for offset in 0..<BudgetSuggestionEngine.maximumTrailingMonthCount {
            guard let start = calendar.date(
                byAdding: .month,
                value: offset,
                to: firstStart
            ), let month = calendar.dateInterval(of: .month, for: start) else {
                throw AppModelError.invalidBook
            }
            months.append(month)
        }
        return BudgetSuggestionContext(
            months: months,
            interval: DateInterval(start: firstStart, end: currentMonth.start),
            timeline: try validatedBudgetConfigurationTimeline(asOf: asOf)
        )
    }

    private func categoryLimitHistories(
        events: [LedgerPostingEvent],
        context: BudgetSuggestionContext
    ) throws -> [CategoryLimitHistory] {
        guard let currency = profile?.baseCurrency else {
            throw AppModelError.invalidBook
        }
        let activeExpenseIDs = Set(accounts.lazy.filter {
            $0.kind == .expense && !$0.isArchived
        }.map(\.id))
        let nodeIDs = Set(budgetNodes.lazy.filter {
            activeExpenseIDs.contains($0.id)
        }.map(\.id))
        let spending = try closedMonthCategorySpending(
            events: events,
            categoryIDs: nodeIDs,
            currency: currency
        )
        return try budgetNodes.compactMap { node in
            guard nodeIDs.contains(node.id) else { return nil }
            var values: [Money] = []
            for month in context.months {
                guard context.timeline.revisions[0].effectiveMonth <= month.start,
                      context.timeline.revision(effectiveAt: month.start)
                        .nodes.contains(where: { $0.id == node.id }) else {
                    continue
                }
                let money = try Money(
                    spending[month.start]?[node.id] ?? .zero,
                    currency: currency
                )
                values.append(money)
            }
            guard values.filter({ $0.amount > .zero }).count
                    >= BudgetSuggestionEngine.minimumCompleteMonthCount else {
                return nil
            }
            return CategoryLimitHistory(
                categoryID: node.id,
                currentLimit: node.limit,
                completeMonthlySpending: values
            )
        }
    }

    private func closedMonthCategorySpending(
        events: [LedgerPostingEvent],
        categoryIDs: Set<UUID>,
        currency: CurrencyCode
    ) throws -> [Date: [UUID: Decimal]] {
        var result: [Date: [UUID: Decimal]] = [:]
        for event in events where categoryIDs.contains(event.posting.accountID)
            && event.posting.money.currency == currency {
            guard let date = event.attributedDate(in: reportingCalendar),
                  let month = reportingCalendar.dateInterval(
                      of: .month,
                      for: date
                  )?.start else { throw AppModelError.invalidBook }
            var categoryAmounts = result[month] ?? [:]
            categoryAmounts[event.posting.accountID] = try CheckedDecimal.adding(
                categoryAmounts[event.posting.accountID] ?? .zero,
                event.posting.money.amount
            )
            result[month] = categoryAmounts
        }
        return result
    }

    private func budgetSuggestionUpdate(
        _ suggestions: [BudgetLimitSuggestion]
    ) throws -> BudgetSuggestionUpdate {
        guard let currency = profile?.baseCurrency,
              !suggestions.isEmpty,
              Set(suggestions.map(\.categoryID)).count == suggestions.count else {
            throw AppModelError.invalidBook
        }
        var candidate = budgetNodes
        var before: [BudgetNode] = []
        var after: [BudgetNode] = []
        for suggestion in suggestions.sorted(by: suggestionOrder) {
            guard suggestion.proposedLimit.currency == currency,
                  let index = candidate.firstIndex(where: {
                      $0.id == suggestion.categoryID
                  }), candidate[index].limit == suggestion.currentLimit else {
                throw AppModelError.invalidBook
            }
            before.append(candidate[index])
            candidate[index] = try budgetNodeUpdating(
                candidate[index],
                amount: suggestion.proposedLimit.amount,
                purpose: nil,
                rolloverRule: nil,
                currency: currency
            )
            after.append(candidate[index])
        }
        _ = try BudgetTree(currency: currency, nodes: candidate)
        return BudgetSuggestionUpdate(
            nodes: candidate,
            changedBefore: before,
            changedAfter: after
        )
    }

    private func budgetNodesRestoring(
        _ patch: BudgetSuggestionPatch
    ) throws -> [BudgetNode] {
        guard let currency = profile?.baseCurrency,
              !patch.before.isEmpty,
              patch.before.map(\.id) == patch.after.map(\.id) else {
            throw AppModelError.invalidBook
        }
        var candidate = budgetNodes
        for (before, after) in zip(patch.before, patch.after) {
            guard let index = candidate.firstIndex(where: { $0.id == after.id }),
                  candidate[index] == after else { throw AppModelError.invalidBook }
            candidate[index] = before
        }
        _ = try BudgetTree(currency: currency, nodes: candidate)
        return candidate
    }

    private func persistBudgetSuggestionNodes(
        _ nodes: [BudgetNode],
        timeline: BudgetConfigurationTimeline
    ) async throws {
        let generation = storeGeneration
        let budgetStore = try requireStore()
        var writes = try nodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes.append(try budgetConfigurationTimelineWrite(timeline))
        try await budgetStore.write(writes)
        guard isCurrentStoreGeneration(generation) else {
            throw AppModelError.locked
        }
    }

    private func suggestionOrder(
        _ lhs: BudgetLimitSuggestion,
        _ rhs: BudgetLimitSuggestion
    ) -> Bool {
        lhs.categoryID.uuidString < rhs.categoryID.uuidString
    }
}

private struct BudgetSuggestionContext {
    let months: [DateInterval]
    let interval: DateInterval
    let timeline: BudgetConfigurationTimeline
}

private struct BudgetSuggestionUpdate {
    let nodes: [BudgetNode]
    let changedBefore: [BudgetNode]
    let changedAfter: [BudgetNode]
}
