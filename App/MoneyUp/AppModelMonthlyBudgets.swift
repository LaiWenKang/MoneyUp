import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct MonthlyBudgetPresentation: Equatable {
    let month: BudgetMonth
    let currency: CurrencyCode
    let progress: [BudgetProgress]
    let summary: BudgetPlanSummary?
    let purposes: [UUID: BudgetPurpose]
}

extension AppModel {
    var budgetCurrencies: [CurrencyCode] {
        var result = Set(accounts.compactMap(\.currency))
        if let base = profile?.baseCurrency { result.insert(base) }
        result.formUnion(budgetNodes.flatMap(\.monthlyAllocations).map(\.currency))
        return result.sorted()
    }

    func setMonthlyBudget(
        categoryID: UUID,
        date: Date,
        currency: CurrencyCode,
        amount: Decimal?,
        mode: BudgetAllocationMode,
        purpose: BudgetPurpose
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let month = try BudgetMonth(containing: date, calendar: reportingCalendar)
        let current = try BudgetMonth(containing: currentDate(), calendar: reportingCalendar)
        guard month >= current else { throw AppModelError.closedBudgetPeriod }
        guard let index = budgetNodes.firstIndex(where: { $0.id == categoryID }) else {
            throw AppModelError.missingRecord
        }
        if let amount { try requireValidNewWriteAmount(amount, currency: currency) }
        let allocation = try MonthlyBudgetAllocation(
            month: month, currency: currency,
            limit: amount.map { try Money($0, currency: currency) },
            mode: mode, purpose: purpose
        )
        var nodes = budgetNodes
        try nodes[index].setMonthlyAllocation(allocation)
        let timeline = try budgetConfigurationTimelineRecording(nodes: nodes)
        let generation = storeGeneration
        try await requireStore().write([
            try RecordWrite(nodes[index], id: categoryID.uuidString, in: .budgetNodes),
            try budgetConfigurationTimelineWrite(timeline)
        ])
        guard isCurrentStoreGeneration(generation) else { return }
        budgetConfigurationTimeline = timeline
        budgetNodes = nodes
    }

    func monthlyBudgetPresentation(
        asOf date: Date,
        currency: CurrencyCode
    ) async -> DerivedValue<MonthlyBudgetPresentation> {
        do {
            let read = try beginLogicalBookRead()
            let revision = budgetNodesRevision
            let journalRevision = journalProjectionRevision
            let calendar = reportingCalendar
            let tree = try reportingBudgetTree(currency: currency, asOf: date)
            guard !budgetConfigurationTimelineInvalid,
                  let interval = calendar.dateInterval(of: .month, for: date),
                  let range = FinancialPeriodBoundary.dayKeyRange(for: interval, calendar: calendar)
            else { throw AppModelError.invalidBook }
            let isClosed = interval.end <= currentDate()
            let events: [LedgerPostingEvent]
            if isClosed {
                events = try await read.store.fetchBudgetPostingEvents(
                    originDayKeyRange: range, excludingEntryIDs: invalidJournalEntryIDs)
            } else {
                events = try await read.store.fetchJournalPostingEvents(
                    originDayKeyRange: range, excludingEntryIDs: invalidJournalEntryIDs)
            }
            let spending = try Self.monthlyDirectSpending(events, tree: tree)
            let rollover = try await monthlyRolloverLimits(tree: tree, date: date, store: read.store)
            try requireLogicalBookRead(read.token)
            guard revision == budgetNodesRevision,
                  journalRevision == journalProjectionRevision else { throw CancellationError() }
            return .available(MonthlyBudgetPresentation(
                month: try BudgetMonth(containing: date, calendar: calendar),
                currency: currency,
                progress: try tree.progress(directSpending: spending, effectiveLimits: rollover),
                summary: try tree.planSummary(directSpending: spending, effectiveLimits: rollover),
                purposes: Dictionary(uniqueKeysWithValues: tree.nodes.map {
                    ($0.id, tree.effectivePurpose(for: $0.id))
                })
            ))
        } catch {
            return .unavailable(.budgetCalculationFailed)
        }
    }

    private func monthlyRolloverLimits(
        tree: BudgetTree,
        date: Date,
        store: EncryptedRecordStore
    ) async throws -> [UUID: Money] {
        guard tree.currency == profile?.baseCurrency else { return [:] }
        let timeline = try validatedBudgetConfigurationTimeline(asOf: currentDate())
        let month = try reportingMonthStart(containing: date)
        guard let start = budgetRolloverReplayStart(
            timeline: timeline, currentMonthStart: month, calendar: reportingCalendar
        ), start < month,
        let range = FinancialPeriodBoundary.dayKeyRange(
            for: DateInterval(start: start, end: month), calendar: reportingCalendar
        ) else {
            return try BudgetRolloverEngine.snapshot(
                timeline: timeline, monthlySpending: [], asOf: date,
                calendar: reportingCalendar
            ).effectiveLimits
        }
        let events = try await store.fetchBudgetPostingEvents(
            originDayKeyRange: range, excludingEntryIDs: invalidJournalEntryIDs
        )
        let periods = try closedMonthBudgetSpending(
            events: events, attributions: [:], currency: tree.currency,
            replayStart: start, currentMonthStart: month, calendar: reportingCalendar,
            excludingEntryIDs: invalidJournalEntryIDs
        )
        return try BudgetRolloverEngine.snapshot(
            timeline: timeline, monthlySpending: periods, asOf: date,
            calendar: reportingCalendar
        ).effectiveLimits
    }

    private static func monthlyDirectSpending(
        _ events: [LedgerPostingEvent], tree: BudgetTree
    ) throws -> [UUID: Money] {
        let ids = Set(tree.nodes.map(\.id))
        var result: [UUID: Money] = [:]
        for event in events {
            let posting = event.posting
            guard ids.contains(posting.accountID), posting.money.currency == tree.currency else { continue }
            result[posting.accountID] = try (result[posting.accountID]
                ?? .zero(currency: tree.currency)).adding(posting.money)
        }
        return result
    }
}
