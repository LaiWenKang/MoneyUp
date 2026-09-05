import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func displayBalanceResult(for account: LedgerAccount) -> DerivedValue<Money> {
        guard let currency = account.currency else {
            return .unavailable(.missingCurrency)
        }
        switch accountBalancesResult() {
        case let .available(balances):
            let raw = balances[account.id]?[currency]
                ?? Money.zero(currency: currency)
            return .available(account.kind == .liability ? raw.negated : raw)
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    /// Authoritative headline ledger net worth, separated by currency.
    /// Holdings are not added here: their hidden position accounts already
    /// carry their value. Policy-bound allowance stored value is intentionally
    /// reported by `restrictedAllowanceValueByCurrencyResult()` instead.
    func netWorthByCurrencyResult() -> DerivedValue<[Money]> {
        var totals: [CurrencyCode: Decimal] = [:]
        for account in allUserAccounts {
            // Provider-controlled or otherwise policy-bound stored value must
            // never be presented as headline or unrestricted wealth.
            guard account.accountType != .restrictedAllowance else { continue }
            guard let currency = account.currency else { continue }
            switch displayBalanceResult(for: account) {
            case let .available(balance):
                do {
                    let current = totals[currency, default: .zero]
                    totals[currency] = account.kind == .liability
                        ? try checkedInvestmentDifference(current, balance.amount)
                        : try checkedEstimatedSum(current, balance.amount)
                } catch {
                    DerivedValueDiagnostics.record(
                        .amountCalculationFailed,
                        operation: "net-worth-by-currency",
                        error: error
                    )
                    return .unavailable(.amountCalculationFailed)
                }
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }
        do {
            return .available(try totals.sorted { $0.key < $1.key }.map {
                try Money($0.value, currency: $0.key)
            })
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }

    /// Returns a combined estimate only when every non-zero foreign component
    /// has an applicable user-entered historical rate. The authoritative
    /// currency-separated totals remain the primary result and are never
    /// partially folded into the base currency.
    func estimatedNetWorthResult(
        at date: Date = Date()
    ) -> DerivedValue<EstimatedNetWorth?> {
        guard let baseCurrency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        let amounts: [Money]
        switch netWorthByCurrencyResult() {
        case let .available(value):
            amounts = value
        case let .unavailable(issue):
            return .unavailable(issue)
        }
        let origin = reportingOriginContext(for: date)
        var total = Decimal.zero
        var evidence: [NetWorthConversionEvidence] = []
        do {
            for amount in amounts where !amount.isZero {
                if amount.currency == baseCurrency {
                    total = try checkedEstimatedSum(total, amount.amount)
                    continue
                }
                guard let conversion = try HistoricalExchangeRateLookup.conversion(
                    of: amount,
                    to: baseCurrency,
                    on: origin,
                    rates: exchangeRates
                ) else {
                    return .available(nil)
                }
                total = try checkedEstimatedSum(
                    total,
                    conversion.converted.amount
                )
                evidence.append(try NetWorthConversionEvidence(
                    source: amount,
                    appliedRate: conversion.appliedRate,
                    rateID: conversion.rateID,
                    effectiveDayKey: conversion.effectiveDayKey,
                    usedInverseRate: conversion.usedInverseRate,
                    converted: conversion.converted
                ))
            }
            guard !evidence.isEmpty,
                  let oldestDayKey = evidence.map(\.effectiveDayKey).min(),
                  let oldestRate = evidence
                    .filter({ $0.effectiveDayKey == oldestDayKey })
                    .compactMap({ item in
                        exchangeRates.first { $0.id == item.rateID }
                    })
                    .first,
                  let conversionAsOf = oldestRate.effectiveContext.attributedDate(
                    in: reportingCalendar
                  ) else {
                return .available(nil)
            }
            return .available(EstimatedNetWorth(
                total: try Money(total, currency: baseCurrency),
                conversionAsOf: conversionAsOf,
                conversionAsOfDayKey: oldestDayKey,
                evidence: evidence.sorted { $0.source.currency < $1.source.currency }
            ))
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "net-worth-estimate",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    /// The period report used by every reporting screen. Results are cached
    /// until the journal changes or the calendar day rolls over, so a SwiftUI
    /// body evaluation never rescans the whole journal.
    func reportResult(
        for period: ReportPeriod,
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<PeriodReport> {
        let calendar = reportingCalendar
        let now = requestedDate ?? currentDate()
        let today = calendar.startOfDay(for: now)
        if reportCacheDay != today {
            reportCache.removeAll()
            reportCacheDay = today
            if !retainsCompleteJournal {
                scheduleJournalDerivedRefresh()
                return .unavailable(.appNotReady)
            }
        }
        if let cached = reportCache[period] { return cached }

        guard retainsCompleteJournal else {
            scheduleJournalDerivedRefresh()
            return .unavailable(.appNotReady)
        }

        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        guard let interval = period.interval(containing: now, calendar: calendar) else {
            DerivedValueDiagnostics.record(
                .invalidPeriod,
                operation: "period-report-interval"
            )
            return .unavailable(.invalidPeriod)
        }
        let trendInterval = ReportPeriod.twelveMonths.interval(
            containing: now,
            calendar: calendar
        )
            ?? interval
        let result: DerivedValue<PeriodReport>
        do {
            result = .available(
                try FinanceCalculator.report(
                    interval: interval,
                    trendInterval: trendInterval,
                    accounts: accounts,
                    entries: entries,
                    baseCurrency: currency,
                    calendar: calendar
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "period-report",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        reportCache[period] = result
        return result
    }

    func spendingThisMonthResult(
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<[UUID: Money]> {
        switch reportResult(for: .thisMonth, asOf: requestedDate) {
        case let .available(report):
            return .available(
                Dictionary(
                    uniqueKeysWithValues: report.categorySpending.map {
                        ($0.accountID, $0.amount)
                    }
                )
            )
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    func excludedForeignSpendingThisMonthResult(
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<[Money]> {
        switch reportResult(for: .thisMonth, asOf: requestedDate) {
        case let .available(report):
            return .available(
                report.foreignFlows
                    .map(\.expense)
                    .filter { $0.amount > .zero }
                    .sorted { $0.currency < $1.currency }
            )
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    /// One validated hierarchy per base-currency/budget revision. Invalid
    /// trees are cached too, so every view in one render observes the same
    /// failure without repeating validation work.
    func reportingBudgetTree(currency: CurrencyCode) throws -> BudgetTree {
        if let budgetTreeCache,
           budgetTreeCache.currency == currency,
           budgetTreeCache.revision == budgetNodesRevision {
            return try budgetTreeCache.result.get()
        }

        let result: Result<BudgetTree, Error>
        do {
            result = .success(try BudgetTree(currency: currency, nodes: budgetNodes))
        } catch {
            result = .failure(error)
        }
        budgetTreeCache = BudgetTreeCacheEntry(
            currency: currency,
            revision: budgetNodesRevision,
            result: result
        )
        budgetTreeCacheBuildCount += 1
        return try result.get()
    }

    func reportingMonthStart(containing date: Date) throws -> Date {
        guard let start = reportingCalendar.dateInterval(of: .month, for: date)?.start else {
            throw AppModelError.invalidBook
        }
        return start
    }

    /// Builds the one-time prospective baseline for a legacy book. The
    /// earliest known rollover activation is retained so the pre-upgrade
    /// calculation remains unchanged until the first dated edit.
    func inferredBudgetConfigurationTimeline(
        nodes: [BudgetNode],
        currency: CurrencyCode,
        asOf: Date
    ) throws -> BudgetConfigurationTimeline {
        let calendar = reportingCalendar
        let currentMonth = try reportingMonthStart(containing: asOf)
        let earliestActivation = nodes.compactMap { node -> Date? in
            guard node.rolloverRule != .none,
                  let startedAt = node.rolloverStartedAt else { return nil }
            return calendar.dateInterval(of: .month, for: startedAt)?.start
        }.min()
        return try BudgetConfigurationTimeline(
            currency: currency,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: earliestActivation ?? currentMonth,
                nodes: nodes
            )]
        )
    }

    func validatedBudgetConfigurationTimeline(
        asOf: Date
    ) throws -> BudgetConfigurationTimeline {
        guard !budgetConfigurationTimelineInvalid,
              let currency = profile?.baseCurrency else {
            throw AppModelError.invalidBook
        }
        let timeline: BudgetConfigurationTimeline
        if let existing = budgetConfigurationTimeline {
            timeline = existing
        } else {
            timeline = try inferredBudgetConfigurationTimeline(
                nodes: budgetNodes,
                currency: currency,
                asOf: asOf
            )
        }
        guard timeline.currency == currency else { throw AppModelError.invalidBook }
        for revision in timeline.revisions {
            guard reportingCalendar.dateInterval(
                of: .month,
                for: revision.effectiveMonth
            )?.start == revision.effectiveMonth else {
                throw AppModelError.invalidBook
            }
        }
        let currentMonth = try reportingMonthStart(containing: asOf)
        let currentTree = try timeline.tree(effectiveAt: currentMonth)
        let timelineNodes = Dictionary(
            uniqueKeysWithValues: currentTree.nodes.map { ($0.id, $0) }
        )
        let loadedNodes = Dictionary(
            uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) }
        )
        guard timelineNodes == loadedNodes else { throw AppModelError.invalidBook }
        return timeline
    }

    func budgetConfigurationTimelineRecording(
        nodes: [BudgetNode],
        carryMappings: [BudgetCarryMapping] = [],
        asOf: Date? = nil
    ) throws -> BudgetConfigurationTimeline {
        let now = asOf ?? currentDate()
        let effectiveMonth = try reportingMonthStart(containing: now)
        let timeline = try validatedBudgetConfigurationTimeline(asOf: now)
        let existingOpeningCarry = timeline.revisions.first {
            $0.effectiveMonth == effectiveMonth
        }?.openingCarryByID
        let openingCarry: [UUID: Money]
        if let existingOpeningCarry {
            openingCarry = existingOpeningCarry
        } else {
            guard let currency = profile?.baseCurrency else {
                throw AppModelError.invalidBook
            }
            let currentTree = try reportingBudgetTree(currency: currency)
            openingCarry = try budgetRolloverSnapshot(
                tree: currentTree,
                timeline: timeline,
                asOf: effectiveMonth
            ).carryIn
        }
        return try timeline.recording(
            nodes: nodes,
            effectiveMonth: effectiveMonth,
            carryMappings: carryMappings,
            openingCarry: openingCarry
        )
    }

    func budgetConfigurationTimelineWrite(
        _ timeline: BudgetConfigurationTimeline
    ) throws -> RecordWrite {
        try RecordWrite(
            timeline,
            id: BudgetConfigurationTimeline.primaryRecordID,
            in: .budgetConfigurationTimelines
        )
    }

    func prepareBudgetConfigurationTimelineAfterLoad(
        in store: EncryptedRecordStore,
        persistsMigration: Bool
    ) async throws {
        guard let profile else {
            if budgetConfigurationTimeline != nil {
                budgetConfigurationTimelineInvalid = true
                recoveryIssues.append("budget_configuration_timelines/orphan-primary")
            }
            return
        }
        guard !budgetConfigurationTimelineInvalid else { return }

        if budgetConfigurationTimeline == nil {
            let migrated = try inferredBudgetConfigurationTimeline(
                nodes: budgetNodes,
                currency: profile.baseCurrency,
                asOf: currentDate()
            )
            if persistsMigration {
                // One generic-record upsert is a SQL transaction. If it fails,
                // startup fails rather than running rollover from an ephemeral
                // baseline that a restart could reinterpret. Rollback recovery
                // alone must preserve the exact pre-restore byte snapshot; its
                // next normal open can persist this inferred legacy baseline.
                try await store.upsert(
                    migrated,
                    id: BudgetConfigurationTimeline.primaryRecordID,
                    in: .budgetConfigurationTimelines
                )
            }
            budgetConfigurationTimeline = migrated
            return
        }

        do {
            let now = currentDate()
            let timeline = try validatedBudgetConfigurationTimeline(
                asOf: now
            )
            let month = try reportingMonthStart(containing: now)
            let currentTree = try timeline.tree(effectiveAt: month)
            let persistedByID = Dictionary(
                uniqueKeysWithValues: currentTree.nodes.map { ($0.id, $0) }
            )
            let loadedByID = Dictionary(
                uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) }
            )
            guard persistedByID == loadedByID else {
                throw AppModelError.invalidBook
            }
        } catch {
            budgetConfigurationTimelineInvalid = true
            recoveryIssues.append("budget_configuration_timelines/inconsistent-primary")
        }
    }

    /// Persists one authoritative carry boundary per reporting month. After
    /// the first indexed replay in a month, recurring unlocks start at this
    /// checkpoint instead of walking the user's complete rollover history.
    func persistCurrentMonthBudgetCheckpointIfNeeded(
        in store: EncryptedRecordStore,
        persistsCheckpoint: Bool
    ) async throws {
        guard persistsCheckpoint,
              recoveryIssues.isEmpty,
              !budgetConfigurationTimelineInvalid,
              let timeline = budgetConfigurationTimeline else { return }
        let now = currentDate()
        let currentMonth = try reportingMonthStart(containing: now)
        guard budgetRolloverReplayStart(
            timeline: timeline,
            currentMonthStart: currentMonth,
            calendar: reportingCalendar
        ) != nil,
        !timeline.revisions.contains(where: {
            $0.effectiveMonth == currentMonth && $0.openingCarry != nil
        }) else { return }

        let tree = try timeline.tree(effectiveAt: currentMonth)
        let carry = try budgetRolloverSnapshot(
            tree: tree,
            timeline: timeline,
            asOf: currentMonth
        ).carryIn
        let checkpointed = try timeline.recording(
            nodes: tree.nodes,
            effectiveMonth: currentMonth,
            openingCarry: carry
        )
        try await store.upsert(
            checkpointed,
            id: BudgetConfigurationTimeline.primaryRecordID,
            in: .budgetConfigurationTimelines
        )
        budgetConfigurationTimeline = checkpointed
    }

    /// A decodable attribution is still untrusted recovery input. Validate it
    /// against only its referenced live journal row, then apply the restore
    /// validator's exact posting/audited-remap rule. A failure preserves the
    /// encrypted records but disables budget projection for this session.
    func validateBudgetEntryAttributionsAfterLoad(
        in store: EncryptedRecordStore
    ) async throws {
        guard !budgetConfigurationTimelineInvalid,
              !budgetEntryAttributions.isEmpty else { return }
        do {
            let generation = storeGeneration
            let recoveredEntries = try await store.fetchJournalEntriesRecovering(
                ids: Set(budgetEntryAttributions.keys)
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            recordHistoryDecodeIssues(recoveredEntries.issues)
            let journalByID = Dictionary(
                uniqueKeysWithValues: recoveredEntries.values.map { ($0.id, $0) }
            )
            try await RestoreCandidateValidator.validateBudgetAttributionIntegrity(
                attributions: Array(budgetEntryAttributions.values),
                journalEntries: Array(journalByID.values),
                journalByID: journalByID,
                accountByID: Dictionary(
                    uniqueKeysWithValues: accounts.map { ($0.id, $0) }
                ),
                in: store
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
        } catch AppModelError.locked {
            throw AppModelError.locked
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            budgetConfigurationTimelineInvalid = true
            budgetEntryAttributions.removeAll()
            closedMonthBudgetProjection = nil
            recordRecoveryIssue(
                "budget_entry_attributions/inconsistent-history"
            )
        }
    }

    func budgetEntryAttribution(
        for entryID: UUID,
        in store: EncryptedRecordStore
    ) async throws -> BudgetEntryAttribution? {
        if let cached = budgetEntryAttributions[entryID] { return cached }
        let attribution = try await store.fetch(
            BudgetEntryAttribution.self,
            id: entryID.uuidString,
            from: .budgetEntryAttributions
        )
        guard attribution?.id == entryID || attribution == nil else {
            throw AppModelError.invalidBook
        }
        if let attribution { budgetEntryAttributions[entryID] = attribution }
        return attribution
    }

    /// Full attribution materialization is reserved for explicit operations
    /// that already need complete historical journal replay (for example a
    /// backdated mutation before a persisted checkpoint). Normal startup and
    /// month-to-month projection stay on the normalized SQL index.
    func loadCompleteBudgetAttributionCacheIfNeeded(
        from store: EncryptedRecordStore
    ) async throws {
        guard !budgetAttributionCacheIsComplete else { return }
        let recovered = try await store.fetchAllIdentifiedRecovering(
            BudgetEntryAttribution.self,
            from: .budgetEntryAttributions
        )
        guard recovered.issues.isEmpty else { throw AppModelError.invalidBook }
        let values = try quarantiningDuplicateLogicalIDs(
            recovered.values,
            in: .budgetEntryAttributions,
            observesCancellation: true
        )
        guard values.count == recovered.values.count else {
            throw AppModelError.invalidBook
        }
        budgetEntryAttributions = Dictionary(
            uniqueKeysWithValues: values.map { ($0.id, $0) }
        )
        budgetAttributionCacheIsComplete = true
    }
}
