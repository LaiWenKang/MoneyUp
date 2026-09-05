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
        let timeline = try validatedBudgetConfigurationTimeline(asOf: currentDate())
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
}
