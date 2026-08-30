import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func budgetPurposeOverview() -> BudgetPurposeOverview {
        guard let currency = profile?.baseCurrency,
              let tree = try? reportingBudgetTree(currency: currency) else {
            return BudgetPurposeOverview(effectivePurposeByID: [:], reviewCount: 0)
        }
        return BudgetPurposeOverview(
            effectivePurposeByID: Dictionary(
                uniqueKeysWithValues: budgetNodes.map {
                    ($0.id, tree.effectivePurpose(for: $0.id))
                }
            ),
            reviewCount: tree.limitedNodesNeedingPurpose.count
        )
    }

    func currentBudgetRolloverSnapshot(
        tree: BudgetTree,
        asOf requestedDate: Date? = nil
    ) throws -> BudgetRolloverSnapshot {
        let asOf = requestedDate ?? currentDate()
        let timeline = try validatedBudgetConfigurationTimeline(asOf: asOf)
        return try budgetRolloverSnapshot(
            tree: tree,
            timeline: timeline,
            asOf: asOf
        )
    }

    func budgetRolloverSnapshot(
        tree: BudgetTree,
        timeline: BudgetConfigurationTimeline,
        asOf: Date,
        journalEntries: [JournalEntry]? = nil,
        attributions: [UUID: BudgetEntryAttribution]? = nil
    ) throws -> BudgetRolloverSnapshot {
        let calendar = reportingCalendar
        guard let currentMonth = calendar.dateInterval(of: .month, for: asOf) else {
            throw AppModelError.invalidBook
        }
        guard let replayStart = budgetRolloverReplayStart(
            timeline: timeline,
            currentMonthStart: currentMonth.start,
            calendar: calendar
        ) else {
            return try BudgetRolloverEngine.snapshot(
                tree: tree,
                monthlySpending: [],
                asOf: asOf,
                calendar: calendar
            )
        }

        let rawPeriods: [MonthlyBudgetSpending]
        if let journalEntries {
            rawPeriods = try closedMonthBudgetSpending(
                entries: journalEntries,
                attributions: attributions ?? budgetEntryAttributions,
                currency: tree.currency,
                replayStart: replayStart,
                currentMonthStart: currentMonth.start,
                calendar: calendar,
                excludingEntryIDs: invalidJournalEntryIDs
            )
        } else if retainsCompleteJournal {
            rawPeriods = try closedMonthBudgetSpending(
                entries: entries,
                attributions: budgetEntryAttributions,
                currency: tree.currency,
                replayStart: replayStart,
                currentMonthStart: currentMonth.start,
                calendar: calendar,
                excludingEntryIDs: invalidJournalEntryIDs
            )
        } else {
            guard let projection = closedMonthBudgetProjection,
                  projection.reportingTimeZoneIdentifier
                    == calendar.timeZone.identifier,
                  projection.currentMonthStart == currentMonth.start,
                  projection.coverageStart <= replayStart,
                  projection.currency == tree.currency else {
                // Never substitute the deliberately bounded recent-entry UI
                // cache. Make the result unavailable until the complete SQL
                // projection for the new boundary has published.
                scheduleJournalDerivedRefresh()
                throw AppModelError.invalidBook
            }
            rawPeriods = projection.monthlySpending
        }

        let periods = rawPeriods.compactMap { period -> MonthlyBudgetSpending? in
            guard FinancialPeriodBoundary.contains(
                period.monthStart,
                start: replayStart,
                endExclusive: currentMonth.start
            ) else { return nil }
            // A backdated recategorization can target a category created only
            // in a later revision. It is honestly unbudgeted in the earlier
            // month, so filter the raw compact projection through that month's
            // historical tree before rollover consumes it.
            let validIDs = Set(
                timeline.revision(effectiveAt: period.monthStart).nodes.map(\.id)
            )
            return MonthlyBudgetSpending(
                monthStart: period.monthStart,
                directSpending: period.directSpending.filter {
                    validIDs.contains($0.key) && $0.value.currency == tree.currency
                }
            )
        }
        return try BudgetRolloverEngine.snapshot(
            timeline: timeline,
            monthlySpending: periods,
            asOf: asOf,
            calendar: calendar
        )
    }

    func budgetRolloverReplayStart(
        timeline: BudgetConfigurationTimeline,
        currentMonthStart: Date,
        calendar: Calendar
    ) -> Date? {
        let activation = timeline.revisions.flatMap(\.nodes).compactMap {
            node -> Date? in
            guard node.rolloverRule != .none,
                  let startedAt = node.rolloverStartedAt else { return nil }
            return calendar.dateInterval(of: .month, for: startedAt)?.start
        }.min()
        let latestCheckpoint = timeline.revisions.last {
            $0.effectiveMonth <= currentMonthStart && $0.openingCarry != nil
        }
        return latestCheckpoint?.effectiveMonth ?? activation
    }

    func closedMonthBudgetSpending(
        entries sourceEntries: [JournalEntry],
        attributions: [UUID: BudgetEntryAttribution],
        currency: CurrencyCode,
        replayStart: Date,
        currentMonthStart: Date,
        calendar: Calendar,
        excludingEntryIDs: Set<UUID>
    ) throws -> [MonthlyBudgetSpending] {
        var amountsByMonth: [Date: [UUID: Decimal]] = [:]
        for entry in sourceEntries where !excludingEntryIDs.contains(entry.id) {
            let attribution = attributions[entry.id]
            let attributedDate: Date
            if let attribution {
                guard let date = attribution.attributedDate(in: calendar) else {
                    throw AppModelError.invalidBook
                }
                attributedDate = date
            } else {
                attributedDate = entry.occurredAt
            }
            try accumulateClosedMonthBudgetPostings(
                attribution?.postings ?? entry.postings,
                attributedDate: attributedDate,
                currency: currency,
                replayStart: replayStart,
                currentMonthStart: currentMonthStart,
                calendar: calendar,
                amountsByMonth: &amountsByMonth
            )
        }
        return try makeMonthlyBudgetSpending(
            amountsByMonth,
            currency: currency
        )
    }

    func closedMonthBudgetSpending(
        events: [LedgerPostingEvent],
        attributions: [UUID: BudgetEntryAttribution],
        currency: CurrencyCode,
        replayStart: Date,
        currentMonthStart: Date,
        calendar: Calendar,
        excludingEntryIDs: Set<UUID>
    ) throws -> [MonthlyBudgetSpending] {
        var amountsByMonth: [Date: [UUID: Decimal]] = [:]
        let attributedEntryIDs = Set(attributions.keys)
        for (entryID, attribution) in attributions
            where !excludingEntryIDs.contains(entryID) {
            guard let attributedDate = attribution.attributedDate(in: calendar) else {
                throw AppModelError.invalidBook
            }
            try accumulateClosedMonthBudgetPostings(
                attribution.postings,
                attributedDate: attributedDate,
                currency: currency,
                replayStart: replayStart,
                currentMonthStart: currentMonthStart,
                calendar: calendar,
                amountsByMonth: &amountsByMonth
            )
        }
        for event in events where !attributedEntryIDs.contains(event.entryID)
            && !excludingEntryIDs.contains(event.entryID) {
            guard let attributedDate = event.attributedDate(in: calendar) else {
                throw AppModelError.invalidBook
            }
            try accumulateClosedMonthBudgetPostings(
                [event.posting],
                attributedDate: attributedDate,
                currency: currency,
                replayStart: replayStart,
                currentMonthStart: currentMonthStart,
                calendar: calendar,
                amountsByMonth: &amountsByMonth
            )
        }
        return try makeMonthlyBudgetSpending(
            amountsByMonth,
            currency: currency
        )
    }

    func accumulateClosedMonthBudgetPostings(
        _ postings: [Posting],
        attributedDate: Date,
        currency: CurrencyCode,
        replayStart: Date,
        currentMonthStart: Date,
        calendar: Calendar,
        amountsByMonth: inout [Date: [UUID: Decimal]]
    ) throws {
        guard FinancialPeriodBoundary.contains(
            attributedDate,
            start: replayStart,
            endExclusive: currentMonthStart
        ), let month = calendar.dateInterval(
            of: .month,
            for: attributedDate
        )?.start else { return }
        for posting in postings where posting.money.currency == currency {
            let prior = amountsByMonth[month]?[posting.accountID] ?? .zero
            do {
                amountsByMonth[month, default: [:]][posting.accountID] =
                    try CheckedDecimal.adding(prior, posting.money.amount)
            } catch {
                throw AppModelError.invalidBook
            }
        }
    }

    func makeMonthlyBudgetSpending(
        _ amountsByMonth: [Date: [UUID: Decimal]],
        currency: CurrencyCode
    ) throws -> [MonthlyBudgetSpending] {
        try amountsByMonth.keys.sorted().map { month in
            MonthlyBudgetSpending(
                monthStart: month,
                directSpending: try amountsByMonth[month, default: [:]].reduce(
                    into: [UUID: Money]()
                ) { result, item in
                    guard item.value != .zero else { return }
                    result[item.key] = try Money(item.value, currency: currency)
                }
            )
        }
    }

    /// Rebuilds only derived opening-carry checkpoints after a backdated
    /// journal mutation. Configuration revisions remain immutable; preserved
    /// attribution lets replay use the category IDs that existed before a
    /// lifecycle merge rewrote the live journal.
    func budgetTimelineRecomputingOpeningCarries(
        _ timeline: BudgetConfigurationTimeline,
        journalEntries: [JournalEntry],
        attributions: [UUID: BudgetEntryAttribution]
    ) throws -> BudgetConfigurationTimeline {
        var revisions = timeline.revisions
        for index in revisions.indices where revisions[index].openingCarry != nil {
            let revision = revisions[index]
            let openingCarry: [UUID: Money]
            if index == revisions.startIndex {
                openingCarry = [:]
            } else {
                let priorTimeline = try BudgetConfigurationTimeline(
                    currency: timeline.currency,
                    revisions: Array(revisions[..<index])
                )
                let priorTree = try priorTimeline.tree(
                    effectiveAt: revision.effectiveMonth
                )
                openingCarry = try budgetRolloverSnapshot(
                    tree: priorTree,
                    timeline: priorTimeline,
                    asOf: revision.effectiveMonth,
                    journalEntries: journalEntries,
                    attributions: attributions
                ).carryIn
            }
            revisions[index] = BudgetConfigurationRevision(
                id: revision.id,
                effectiveMonth: revision.effectiveMonth,
                nodes: revision.nodes,
                carryMappings: revision.carryMappings,
                openingCarry: openingCarry
            )
        }
        return try BudgetConfigurationTimeline(
            currency: timeline.currency,
            revisions: revisions
        )
    }

    func budgetTimelineAfterJournalMutation(
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil,
        journalEntries: [JournalEntry],
        attributions: [UUID: BudgetEntryAttribution],
        affectedReportingMonths: [Date]
    ) throws -> BudgetConfigurationTimeline? {
        guard !budgetConfigurationTimelineInvalid,
              let earliestAffected = affectedReportingMonths.min(),
              let timeline = candidateTimeline ?? budgetConfigurationTimeline,
              timeline.revisions.contains(where: {
                  $0.openingCarry != nil && earliestAffected < $0.effectiveMonth
              }) else {
            return nil
        }
        return try budgetTimelineRecomputingOpeningCarries(
            timeline,
            journalEntries: journalEntries,
            attributions: attributions
        )
    }

    func budgetCheckpointNeedsJournalReplay(
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil,
        affectedReportingMonths: [Date]
    ) -> Bool {
        !budgetConfigurationTimelineInvalid
            && laterBudgetCheckpointExists(
                timeline: candidateTimeline,
                affectedReportingMonths: affectedReportingMonths
            )
    }

    func laterBudgetCheckpointExists(
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil,
        affectedReportingMonths: [Date]
    ) -> Bool {
        guard let earliestAffected = affectedReportingMonths.min(),
              let timeline = candidateTimeline ?? budgetConfigurationTimeline else {
            return false
        }
        return timeline.revisions.contains {
            $0.openingCarry != nil && earliestAffected < $0.effectiveMonth
        }
    }

    /// Retained mode still needs a candidate array for its in-memory journal.
    /// Lazy mode materializes the complete journal only when a later persisted
    /// opening carry can actually change.
    func journalEntriesForBudgetMutation(
        from journalStore: EncryptedRecordStore,
        affectedReportingMonths: [Date]
    ) async throws -> [JournalEntry]? {
        if budgetConfigurationTimelineInvalid,
           laterBudgetCheckpointExists(
               affectedReportingMonths: affectedReportingMonths
           ) {
            // Saving without replay would make a persisted checkpoint silently
            // stale after the quarantined budget data is repaired.
            throw AppModelError.invalidBook
        }
        if retainsCompleteJournal { return entries }
        guard budgetCheckpointNeedsJournalReplay(
            affectedReportingMonths: affectedReportingMonths
        ) else {
            return nil
        }

        try await loadCompleteBudgetAttributionCacheIfNeeded(
            from: journalStore
        )
        budgetJournalReplayReadCount += 1
        let generation = storeGeneration
        let recovered = try await journalStore.fetchAllIdentifiedRecovering(
            JournalEntry.self,
            from: .journalEntries
        )
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        recordHistoryDecodeIssues(recovered.issues)
        guard Set(recovered.values.map(\.id)).count == recovered.values.count else {
            recordRecoveryIssue("journal_entries/duplicate-logical-identity")
            throw AppModelError.invalidBook
        }

        let malformedIDs = Set(recovered.issues.compactMap {
            UUID(uuidString: $0.recordID)
        })
        let validAccountIDs = Set(accounts.map(\.id))
        let expectedAccountCurrencies = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account in
                account.currency.map { (account.id, $0) }
            }
        )
        var newlyQuarantined = Set<UUID>()
        for entry in recovered.values where !invalidJournalEntryIDs.contains(entry.id) {
            let isValid = entry.postings.allSatisfy { posting in
                guard validAccountIDs.contains(posting.accountID) else { return false }
                return expectedAccountCurrencies[posting.accountID].map {
                    $0 == posting.money.currency
                } ?? true
            }
            if !isValid { newlyQuarantined.insert(entry.id) }
        }
        if !newlyQuarantined.isEmpty {
            invalidJournalEntryIDs.formUnion(newlyQuarantined)
            recordHistoryDecodeIssues(newlyQuarantined.map {
                RecordDecodeIssue(
                    collection: .journalEntries,
                    recordID: $0.uuidString
                )
            })
        }
        let excludedIDs = invalidJournalEntryIDs.union(malformedIDs)
        return recovered.values.filter { !excludedIDs.contains($0.id) }
    }

    func budgetAffectedMonth(
        for entry: JournalEntry,
        attribution: BudgetEntryAttribution?,
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil
    ) throws -> Date? {
        let timeline = candidateTimeline ?? budgetConfigurationTimeline
        guard let timeline else { return nil }
        let budgetIDs = Set(timeline.revisions.flatMap(\.nodes).map(\.id))
        let postings = attribution?.postings ?? entry.postings
        guard postings.contains(where: { budgetIDs.contains($0.accountID) }) else {
            return nil
        }
        let date: Date
        if let attribution {
            guard let attributedDate = attribution.attributedDate(
                in: reportingCalendar
            ) else { throw AppModelError.invalidBook }
            date = attributedDate
        } else {
            date = entry.occurredAt
        }
        guard let month = reportingCalendar.dateInterval(
            of: .month,
            for: date
        )?.start else {
            throw AppModelError.invalidBook
        }
        return month
    }

    func budgetProgressThisMonthResult(
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<[BudgetProgress]> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        let date = requestedDate ?? currentDate()
        do {
            let tree = try reportingBudgetTree(currency: currency)
            let rollover = try currentBudgetRolloverSnapshot(tree: tree, asOf: date)
            switch spendingThisMonthResult(asOf: date) {
            case let .available(spending):
                return .available(try tree.progress(
                    directSpending: spendingRepresented(in: tree, from: spending),
                    effectiveLimits: rollover.effectiveLimits
                ))
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "budget-progress",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    func budgetPlanSummaryThisMonthResult(
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<BudgetPlanSummary?> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        let date = requestedDate ?? currentDate()
        do {
            let tree = try reportingBudgetTree(currency: currency)
            let rollover = try currentBudgetRolloverSnapshot(tree: tree, asOf: date)
            switch spendingThisMonthResult(asOf: date) {
            case let .available(spending):
                return .available(try tree.planSummary(
                    directSpending: spendingRepresented(in: tree, from: spending),
                    effectiveLimits: rollover.effectiveLimits
                ))
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "budget-summary",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    func flexibleTodayResult(
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<FlexibleTodayStatus> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        let date = requestedDate ?? currentDate()
        let spending: [UUID: Money]
        switch spendingThisMonthResult(asOf: date) {
        case let .available(values):
            spending = values
        case let .unavailable(issue):
            return .unavailable(issue)
        }
        let foreignSpending: [Money]
        switch excludedForeignSpendingThisMonthResult(asOf: date) {
        case let .available(values):
            foreignSpending = values
        case let .unavailable(issue):
            return .unavailable(issue)
        }

        do {
            let tree = try reportingBudgetTree(currency: currency)
            let rollover = try currentBudgetRolloverSnapshot(tree: tree, asOf: date)
            let representedSpending = spendingRepresented(in: tree, from: spending)
            guard try tree.planSummary(
                directSpending: representedSpending,
                effectiveLimits: rollover.effectiveLimits
            ) != nil else {
                return .available(.needsBudget)
            }
            let unclassifiedCount = tree.limitedNodesNeedingPurpose.count
            guard unclassifiedCount == 0 else {
                return .available(.needsClassification(count: unclassifiedCount))
            }
            guard let flexibleSummary = try tree.planSummary(
                directSpending: representedSpending,
                purpose: .flexible,
                effectiveLimits: rollover.effectiveLimits
            ) else {
                return .available(.needsFlexibleBudget)
            }
            guard let breakdown = try FinanceCalculator.flexibleToday(
                flexibleBudgetRemaining: flexibleSummary.remaining,
                schedules: scheduledTransactions,
                flexibleCategoryIDs: tree.categoryIDs(governedBy: .flexible),
                excludedForeignSpending: foreignSpending,
                asOf: date,
                calendar: reportingCalendar
            ) else {
                return .unavailable(.invalidPeriod)
            }
            return .available(.available(breakdown))
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "flexible-today",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    /// An expense account can legitimately exist without a configured budget
    /// node (for example after an older-book migration). Such spending remains
    /// unbudgeted; it must not make every configured budget unavailable through
    /// `BudgetTreeError.unknownSpendingNode`.
    func spendingRepresented(
        in tree: BudgetTree,
        from spending: [UUID: Money]
    ) -> [UUID: Money] {
        let representedIDs = Set(tree.nodes.map(\.id))
        return spending.filter { representedIDs.contains($0.key) }
    }

    /// Compares equal elapsed portions of this month and the prior month.
    /// A full prior month against a partial current month would produce a
    /// dramatic but misleading “spending down” sentence early in the month.
    func monthToDateExpenseComparisonResult() -> DerivedValue<MonthToDateExpenseComparison> {
        let calendar = reportingCalendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        if monthToDateComparisonCacheDay == today,
           let cached = monthToDateComparisonCache {
            return cached
        }

        guard retainsCompleteJournal else {
            scheduleJournalDerivedRefresh()
            return .unavailable(.appNotReady)
        }

        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        guard let intervals = MonthToDateComparisonIntervals(
            containing: now,
            calendar: calendar
        ) else {
            DerivedValueDiagnostics.record(
                .invalidPeriod,
                operation: "month-to-date-interval"
            )
            return .unavailable(.invalidPeriod)
        }

        let result: DerivedValue<MonthToDateExpenseComparison>
        do {
            let currentReport = try FinanceCalculator.report(
                interval: intervals.current,
                accounts: accounts,
                entries: entries,
                baseCurrency: currency,
                calendar: calendar
            )
            let previousReport = try FinanceCalculator.report(
                interval: intervals.previous,
                accounts: accounts,
                entries: entries,
                baseCurrency: currency,
                calendar: calendar
            )
            result = .available(
                MonthToDateExpenseComparison(
                    previous: previousReport.baseFlow.expense,
                    current: currentReport.baseFlow.expense,
                    holdsUnconvertedActivity: currentReport.holdsUnconvertedActivity
                        || previousReport.holdsUnconvertedActivity
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "month-to-date-comparison",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        monthToDateComparisonCache = result
        monthToDateComparisonCacheDay = today
        return result
    }
}
