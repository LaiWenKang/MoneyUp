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
    }

    func refreshBudgetWidgetSnapshot() {
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
        refreshWidgetInsights(asOf: now)
        guard let period = reportingCalendar.dateInterval(of: .month, for: now),
              let periodToken = BudgetWidgetSnapshotStore.periodToken(
                  for: period.start,
                  calendar: reportingCalendar
              ) else {
            budgetWidgetSnapshotStore.publish(
                enabled: true,
                percentUsed: nil
            )
            WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
            return
        }

        let percentage: Int?
        if case let .available(.some(summary)) = budgetPlanSummaryThisMonthResult(
            asOf: now
        ),
           summary.limit.amount > .zero {
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
                percentage = NSDecimalNumber(decimal: clamped).intValue
            } catch {
                percentage = nil
            }
        } else {
            percentage = nil
        }
        budgetWidgetSnapshotStore.publish(
            enabled: true,
            percentUsed: percentage,
            periodToken: periodToken,
            validUntil: period.end
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    func disableBudgetWidgetSnapshot() {
        budgetWidgetSnapshotStore.publish(enabled: false, percentUsed: nil)
        budgetWidgetSnapshotStore.publishInsights(enabled: false)
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    func refreshWidgetInsights(asOf now: Date) {
        guard let validUntil = reportingCalendar.dateInterval(of: .day, for: now)?.end else {
            budgetWidgetSnapshotStore.publishInsights(enabled: false)
            return
        }
        let activeAllowances = allowancePlans.compactMap { plan -> AllowanceSummary? in
            guard !plan.isArchived,
                  case let .available(summary) = allowanceSummary(plan, asOf: now),
                  summary.isAvailableToday else { return nil }
            return summary
        }
        var entitlement = Decimal.zero
        var remaining = Decimal.zero
        for summary in activeAllowances {
            guard summary.entitlement.currency == profile?.baseCurrency else { continue }
            entitlement = (try? CheckedDecimal.adding(
                entitlement,
                summary.entitlement.amount
            )) ?? entitlement
            remaining = (try? CheckedDecimal.adding(
                remaining,
                summary.remaining.amount
            )) ?? remaining
        }
        let allowancePercent: Int?
        if entitlement > .zero,
           let ratio = try? CheckedDecimal.ratio(remaining, entitlement),
           var raw = try? CheckedDecimal.multiplying(ratio, 100) {
            var rounded = Decimal.zero
            NSDecimalRound(&rounded, &raw, 0, .plain)
            allowancePercent = NSDecimalNumber(decimal: rounded).intValue
        } else {
            allowancePercent = nil
        }
        let activeSchedules = scheduledTransactions.filter(\.isActive)
        let nextCommitment = activeSchedules.compactMap {
            $0.occurrence(onOrAfter: now, calendar: reportingCalendar)
        }.min()
        budgetWidgetSnapshotStore.publishInsights(
            enabled: true,
            reviewCount: intelligenceFindings.count,
            activeAllowanceCount: activeAllowances.count,
            allowancePercentRemaining: allowancePercent,
            activeCommitmentCount: activeSchedules.count,
            nextCommitment: nextCommitment,
            validUntil: validUntil
        )
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
        attachmentDrafts: [ReceiptAttachmentDraft] = []
    ) async throws -> UUID? {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let context = try prepareJournalSave(entry)
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
