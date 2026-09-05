import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
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
            let tree = try reportingBudgetTree(currency: currency, asOf: date)
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
            let tree = try reportingBudgetTree(currency: currency, asOf: date)
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
            let tree = try reportingBudgetTree(currency: currency, asOf: date)
            let rollover = try currentBudgetRolloverSnapshot(tree: tree, asOf: date)
            let representedSpending = spendingRepresented(in: tree, from: spending)
            guard try tree.planSummary(
                directSpending: representedSpending,
                effectiveLimits: rollover.effectiveLimits
            ) != nil else {
                return .available(.needsBudget)
            }
            let unclassifiedCount = tree.nodesNeedingPurpose(directSpending: representedSpending).count
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
