import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

private struct JournalSaveContext {
    let entry: JournalEntry
    let completedLockedCaptureID: UUID?
    let generation: Int
    let currentDraft: QuickLogDraft?
    let store: EncryptedRecordStore
    let pendingDraftWrite: Task<Void, Never>?
}

private struct JournalSaveBudgetCandidate {
    let attributions: [UUID: BudgetEntryAttribution]
    let entries: [JournalEntry]?
    let timeline: BudgetConfigurationTimeline?
}

private struct JournalSaveWriteCandidate {
    let writes: [RecordWrite]
    let receiptAttachments: [ReceiptAttachment]
}

extension AppModel {
    func invalidateDerivedData() {
        reportCache.removeAll()
        monthToDateComparisonCache = nil
        monthToDateComparisonCacheDay = nil
        balanceCache = nil
        services.ledger.restrictedAllowanceBalanceProjection = nil
    }

    func refreshBudgetWidgetSnapshot() {
        guard !manualJournalMutationIsActive else {
            widgetSnapshotRefreshWasDeferred = true
            return
        }
        widgetSnapshotRefreshWasDeferred = false
        // A nil profile during normal lock is intentional: the last explicitly
        // opted-in percentage remains available to the Lock/Home widget. Only
        // destructive erase or a confirmed no-book startup calls the explicit
        // disable helper below.
        guard !isBookReplacementInProgress,
              startupFailureKind != .missingDeviceBoundKey,
              let profile else { return }
        guard profile.showsBudgetStatusWidget else {
            disableBudgetWidgetSnapshot()
            return
        }
        let now = currentDate()
        guard let period = reportingCalendar.dateInterval(of: .month, for: now),
              let periodToken = BudgetWidgetSnapshotStore.periodToken(
                  for: period.start,
                  calendar: reportingCalendar
              ) else {
            budgetWidgetSnapshotStore.publish(
                .stale
            )
            WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
            rearmWidgetReportingDayRefreshIfEligible()
            return
        }

        let snapshot = currentBudgetWidgetSnapshot(
            asOf: now,
            validUntil: period.end
        )
        let insights: MoneyUpWidgetInsights?
        switch snapshot {
        case .available, .needsBudget, .zeroBudget, .negativeBudget:
            insights = widgetInsights(asOf: now)
        case .disabled, .stale:
            insights = nil
        }
        budgetWidgetSnapshotStore.publish(
            snapshot,
            periodToken: periodToken,
            insights: insights
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
        rearmWidgetReportingDayRefreshIfEligible()
    }

    func currentBudgetWidgetSnapshot(
        asOf now: Date,
        validUntil: Date
    ) -> BudgetWidgetSnapshot {
        switch budgetPlanSummaryThisMonthResult(asOf: now) {
        case .available(nil):
            return .needsBudget(validUntil: validUntil)
        case let .available(.some(summary)):
            if summary.limit.amount == .zero {
                // Zero is a valid, intentional monthly plan (for example a
                // no-spend month). It has no meaningful percentage, but it is
                // neither missing nor waiting for a refresh.
                return .zeroBudget(validUntil: validUntil)
            }
            guard summary.limit.amount > .zero else {
                // Full-balance rollover can truthfully make the effective
                // monthly capacity negative. That stable state also has no
                // meaningful percentage and must not masquerade as zero.
                return .negativeBudget(validUntil: validUntil)
            }
            do {
                var raw = try CheckedDecimal.multiplying(
                    CheckedDecimal.ratio(
                        summary.spent.amount,
                        summary.limit.amount
                    ),
                    100
                )
                var rounded = Decimal.zero
                NSDecimalRound(&rounded, &raw, 0, .plain)
                let clamped = min(max(rounded, .zero), Decimal(9_999))
                return .available(
                    percentUsed: NSDecimalNumber(decimal: clamped).intValue,
                    validUntil: validUntil
                )
            } catch {
                return .stale
            }
        case .unavailable:
            return .stale
        }
    }

    func disableBudgetWidgetSnapshot() {
        cancelWidgetReportingDayRefresh()
        budgetWidgetSnapshotStore.publish(.disabled)
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    func widgetInsights(asOf now: Date) -> MoneyUpWidgetInsights? {
        guard let dayEnd = reportingCalendar.dateInterval(of: .day, for: now)?.end else {
            return nil
        }
        let allowancePercent = widgetAllowancePercentRemaining(asOf: now)
        let validUntil = min(
            dayEnd,
            restrictedAllowanceProjectionExpiry(after: now) ?? dayEnd
        )
        // Smart Overview's commitment surface is an outflow warning. Income
        // schedules are useful forecasts, but counting them here would make an
        // incoming salary look like money the user owes.
        let activeCommitments = scheduledTransactions.filter {
            $0.isActive && $0.kind == .expense
        }
        let nextCommitment = activeCommitments.compactMap {
            $0.occurrence(onOrAfter: now, calendar: reportingCalendar)
        }.min()
        let daysUntilNextCommitment = nextCommitment.flatMap { date -> Int? in
            let today = reportingCalendar.startOfDay(for: now)
            let commitmentDay = reportingCalendar.startOfDay(for: date)
            guard let days = reportingCalendar.dateComponents(
                [.day],
                from: today,
                to: commitmentDay
            ).day else { return nil }
            return min(max(days, 0), 9_999)
        }
        let currentReviewCount: Int? = if profile?.intelligenceEnabled == true,
                                          widgetIntelligencePublication.resultsAreCurrent,
                                          !intelligenceService.isRefreshing,
                                          !intelligenceService.isUnavailable {
            intelligenceFindings.count
        } else {
            nil
        }
        return MoneyUpWidgetInsights(
            reviewCount: currentReviewCount,
            allowancePercentRemaining: allowancePercent,
            activeCommitmentCount: activeCommitments.count,
            daysUntilNextCommitment: daysUntilNextCommitment,
            validUntil: validUntil
        )
    }

    private func widgetAllowancePercentRemaining(asOf now: Date) -> Int? {
        guard let baseCurrency = profile?.baseCurrency else { return nil }
        var entitlement = Decimal.zero
        var remaining = Decimal.zero
        do {
            for plan in allowancePlans where !plan.isArchived {
                let presentation = allowancePresentation(plan, asOf: now)
                guard let summary = presentation.policySummary else { return nil }
                guard summary.isAvailableToday else { continue }
                guard case let .available(displayRemaining) =
                    presentation.remaining else { return nil }
                guard summary.entitlement.currency == baseCurrency,
                      summary.used.currency == baseCurrency,
                      displayRemaining.currency == baseCurrency else { return nil }
                entitlement = try CheckedDecimal.adding(
                    entitlement,
                    summary.entitlement.amount
                )
                remaining = try CheckedDecimal.adding(
                    remaining,
                    displayRemaining.amount
                )
            }
            guard entitlement > .zero else { return nil }
            let ratio = try CheckedDecimal.ratio(remaining, entitlement)
            var raw = try CheckedDecimal.multiplying(ratio, 100)
            var rounded = Decimal.zero
            NSDecimalRound(&rounded, &raw, 0, .plain)
            return NSDecimalNumber(decimal: rounded).intValue
        } catch {
            return nil
        }
    }

    func accountBalancesResult() -> DerivedValue<[UUID: [CurrencyCode: Money]]> {
        if let balanceCache { return balanceCache }
        guard retainsCompleteJournal else {
            scheduleJournalDerivedRefresh()
            return .unavailable(.appNotReady)
        }
        let result: DerivedValue<[UUID: [CurrencyCode: Money]]>
        do {
            result = .available(
                try FinanceCalculator.balancesByAccount(entries: entries)
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "account-balances",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        balanceCache = result
        return result
    }

    @discardableResult
    func save(
        _ entry: JournalEntry,
        additionalWrites: [RecordWrite] = [],
        additionalAccounts: [LedgerAccount] = [],
        receiptData: Data? = nil,
        attachmentDrafts: [ReceiptAttachmentDraft] = [],
        authorizedRestrictedAllowanceAccountID: UUID? = nil,
        journalMutationAlreadyBegun: Bool = false
    ) async throws -> UUID? {
        if journalMutationAlreadyBegun,
           !manualJournalMutationIsActive {
            throw AppModelError.transactionInProgress
        }
        try rejectRestrictedAllowanceDebit(
            in: entry,
            authorizedAccountID: authorizedRestrictedAllowanceAccountID
        )
        if !journalMutationAlreadyBegun { try beginJournalMutation() }
        defer {
            if !journalMutationAlreadyBegun { endJournalMutation() }
        }
        let context = try prepareJournalSave(entry)
        try await requireNonnegativeRestrictedBalances(
            afterRemoving: nil,
            adding: context.entry,
            in: context.store
        )
        let attribution = try BudgetEntryAttribution(
            entry: context.entry,
            originTimeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                ?? reportingCalendar.timeZone.identifier
        )
        let budgetCandidate = try await journalSaveBudgetCandidate(
            entry: context.entry,
            attribution: attribution,
            store: context.store
        )
        let writeCandidate = try journalSaveWriteCandidate(
            entry: context.entry,
            attribution: attribution,
            additionalWrites: additionalWrites,
            receiptData: receiptData,
            attachmentDrafts: attachmentDrafts,
            timeline: budgetCandidate.timeline
        )
        if let completedLockedCaptureID = context.completedLockedCaptureID {
            try await completeLockedCaptureBeforeJournalCommit(
                id: completedLockedCaptureID,
                currentDraft: context.currentDraft,
                pendingDraftWrite: context.pendingDraftWrite,
                store: context.store,
                generation: context.generation
            )
        }
        let commitTask = journalCommitTask(
            pendingDraftWrite: context.pendingDraftWrite,
            store: context.store,
            writes: writeCandidate.writes
        )
        let commitID = UUID()
        quickLogCommit = PendingQuickLogCommit(
            id: commitID,
            generation: context.generation,
            task: commitTask
        )
        defer {
            if quickLogCommit?.id == commitID {
                quickLogCommit = nil
            }
        }
        try await commitTask.value
        await lifecycleHooks.checkpoint(
            .afterJournalCommitBeforeProjectionRefresh
        )
        guard isCurrentStoreGeneration(context.generation) else { return nil }
        await publishSavedJournalEntry(
            context: context,
            budgetCandidate: budgetCandidate,
            receiptAttachments: writeCandidate.receiptAttachments,
            additionalAccounts: additionalAccounts
        )
        return context.entry.id
    }

    private func prepareJournalSave(
        _ entry: JournalEntry
    ) throws -> JournalSaveContext {
        let completedLockedCaptureID = quickLogDraft?.sourceCaptureID
        let authoredEntry = try appAuthoredEntry(
            entry,
            sourceSystemOverride: completedLockedCaptureID == nil
                ? nil : Self.lockedCaptureSourceSystem,
            sourceFingerprintOverride: completedLockedCaptureID.map(
                Self.lockedCaptureFingerprint
            )
        )
        let generation = storeGeneration
        let currentDraft = quickLogDraft
        if let existingCommit = quickLogCommit {
            guard existingCommit.generation != generation else {
                throw AppModelError.transactionInProgress
            }
            quickLogCommit = nil
        }
        let transactionStore = try requireStore()
        let pendingDraftWrite = quickLogDraftWriteTask
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        return JournalSaveContext(
            entry: authoredEntry,
            completedLockedCaptureID: completedLockedCaptureID,
            generation: generation,
            currentDraft: currentDraft,
            store: transactionStore,
            pendingDraftWrite: pendingDraftWrite
        )
    }

    private func journalSaveBudgetCandidate(
        entry: JournalEntry,
        attribution: BudgetEntryAttribution,
        store: EncryptedRecordStore
    ) async throws -> JournalSaveBudgetCandidate {
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions[entry.id] = attribution
        let affectedMonths = [
            try budgetAffectedMonth(for: entry, attribution: attribution)
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: store,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions[entry.id] = attribution
            candidateEntries?.append(entry)
            candidateEntries?.sort {
                if $0.occurredAt == $1.occurredAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.occurredAt > $1.occurredAt
            }
        }
        let candidateTimeline: BudgetConfigurationTimeline?
        if let candidateEntries {
            candidateTimeline = try budgetTimelineAfterJournalMutation(
                journalEntries: candidateEntries,
                attributions: candidateAttributions,
                affectedReportingMonths: affectedMonths
            )
        } else {
            candidateTimeline = nil
        }
        return JournalSaveBudgetCandidate(
            attributions: candidateAttributions,
            entries: candidateEntries,
            timeline: candidateTimeline
        )
    }

    private func journalSaveWriteCandidate(
        entry: JournalEntry,
        attribution: BudgetEntryAttribution,
        additionalWrites: [RecordWrite],
        receiptData: Data?,
        attachmentDrafts: [ReceiptAttachmentDraft],
        timeline: BudgetConfigurationTimeline?
    ) throws -> JournalSaveWriteCandidate {
        var pendingWrites = additionalWrites
        var drafts = attachmentDrafts
        if let receiptData {
            drafts.append(try ReceiptAttachmentDraft(
                mediaType: .detected(from: receiptData),
                data: receiptData
            ))
        }
        try ReceiptAttachment.validateEntryLimits(adding: drafts)
        let receiptAttachments = try drafts.map {
            try $0.attached(to: entry.id)
        }
        for createdAttachment in receiptAttachments {
            pendingWrites.append(
                try RecordWrite(
                    createdAttachment,
                    id: createdAttachment.id.uuidString,
                    in: .receiptAttachments
                )
            )
        }
        pendingWrites.append(
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        )
        pendingWrites.append(
            try RecordWrite(
                attribution,
                id: attribution.id.uuidString,
                in: .budgetEntryAttributions
            )
        )
        if let timeline {
            pendingWrites.append(try budgetConfigurationTimelineWrite(timeline))
        }
        return JournalSaveWriteCandidate(
            writes: pendingWrites,
            receiptAttachments: receiptAttachments
        )
    }

    private func completeLockedCaptureBeforeJournalCommit(
        id: UUID,
        currentDraft: QuickLogDraft?,
        pendingDraftWrite: Task<Void, Never>?,
        store: EncryptedRecordStore,
        generation: Int
    ) async throws {
        guard let currentDraft,
              currentDraft.sourceCaptureID == id else {
            throw AppModelError.invalidBook
        }
        await pendingDraftWrite?.value
        try await store.upsert(
            currentDraft,
            id: QuickLogDraft.primaryRecordID,
            in: .quickLogDrafts
        )
        let remainingCaptureCount = try await lockedCaptureStore.remove(id: id)
        guard ownsStoreGeneration(generation) else {
            throw AppModelError.locked
        }
        pendingLockedCaptureCount = remainingCaptureCount
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
    }

    private func journalCommitTask(
        pendingDraftWrite: Task<Void, Never>?,
        store: EncryptedRecordStore,
        writes: [RecordWrite]
    ) -> Task<Void, Error> {
        Task {
            await pendingDraftWrite?.value
            await lifecycleHooks.checkpoint(.beforeJournalCommit)
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
            try await store.write(
                writes,
                removing: [
                    RecordDeletion(
                        id: QuickLogDraft.primaryRecordID,
                        from: .quickLogDrafts
                    )
                ]
            )
        }
    }

    private func publishSavedJournalEntry(
        context: JournalSaveContext,
        budgetCandidate: JournalSaveBudgetCandidate,
        receiptAttachments: [ReceiptAttachment],
        additionalAccounts: [LedgerAccount]
    ) async {
        quickLogDraft = nil
        if !additionalAccounts.isEmpty {
            accounts.append(contentsOf: additionalAccounts)
        }
        receiptAttachmentMetadata.append(
            contentsOf: receiptAttachments.map(ReceiptAttachmentMetadata.init)
        )
        if let timeline = budgetCandidate.timeline {
            budgetConfigurationTimeline = timeline
        }
        budgetEntryAttributions = budgetCandidate.attributions
        if retainsCompleteJournal, let entries = budgetCandidate.entries {
            self.entries = entries
        }
        await refreshJournalAfterMutation()
        guard context.completedLockedCaptureID != nil else { return }
        do {
            try await promoteLockedCaptureIfPossible(
                to: context.store,
                generation: context.generation,
                requestLogRoute: false
            )
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
        } catch {
            // The journal entry is already durable. Surface a safe recovery
            // signal instead of reporting Save as failed.
            recordRecoveryIssue("locked_captures/promotion-unavailable")
        }
    }

    func scheduleQuickLogDraftWrite(_ draft: QuickLogDraft?) {
        let previousWrite = quickLogDraftWriteTask
        previousWrite?.cancel()
        guard let draftStore = store else {
            quickLogDraftWriteTask = nil
            return
        }

        quickLogDraftWriteTask = Task {
            // Chain revisions so Save/Lock can await one task and know every
            // older draft write has also finished before deleting or closing.
            await previousWrite?.value
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await lifecycleHooks.checkpoint(.beforeQuickLogDraftWrite)
            guard !Task.isCancelled else { return }
            await writeQuickLogDraft(draft, to: draftStore)
        }
    }

    /// Replaces the debounce with a chained immediate write. Keeping the
    /// previous task in the chain ensures an older draft can never land after
    /// the latest inactivity snapshot.
    func flushQuickLogDraftImmediately() {
        // Restore and journal commit own the durable draft boundary. Starting
        // a convenience write inside either transaction could resurrect the
        // pre-transaction form after its authoritative commit. Their normal
        // completion/lock path performs the required final flush instead.
        guard !isLifecycleMutationInProgress,
              !isJournalMutationInProgress,
              quickLogCommit == nil else { return }
        let previousWrite = quickLogDraftWriteTask
        previousWrite?.cancel()
        guard let draftStore = store else {
            quickLogDraftWriteTask = nil
            return
        }
        let draft = quickLogDraft
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Save MoneyUp draft",
            expirationHandler: nil
        )

        quickLogDraftWriteTask = Task {
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            await previousWrite?.value
            await lifecycleHooks.checkpoint(.beforeQuickLogDraftWrite)
            await writeQuickLogDraft(draft, to: draftStore)
        }
    }

    /// Deterministic lifecycle synchronization without timing sleeps.
    func waitForPendingQuickLogDraftFlush() async {
        await quickLogDraftWriteTask?.value
    }

    func writeQuickLogDraft(
        _ draft: QuickLogDraft?,
        to draftStore: EncryptedRecordStore
    ) async {
        do {
            if let draft {
                try await draftStore.upsert(
                    draft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            } else {
                try await draftStore.remove(
                    id: QuickLogDraft.primaryRecordID,
                    from: .quickLogDrafts
                )
            }
        } catch {
            // A draft is a convenience cache. A write failure must never block
            // locking or make a completed transaction appear to have failed.
        }
    }

    /// Rebuilds only compact derived state from the normalized encrypted
    /// ledger index. No full `JournalEntry` collection is decoded or retained.
}
