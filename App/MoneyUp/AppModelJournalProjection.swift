import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

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
        guard let profile else { return }
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
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
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
        receiptData: Data? = nil
    ) async throws -> UUID? {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let completedLockedCaptureID = quickLogDraft?.sourceCaptureID
        let entry = try appAuthoredEntry(
            entry,
            sourceSystemOverride: completedLockedCaptureID == nil
                ? nil : "MoneyUp Locked Capture",
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
        let attribution = try BudgetEntryAttribution(
            entry: entry,
            originTimeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                ?? reportingCalendar.timeZone.identifier
        )
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions[entry.id] = attribution
        let affectedMonths = [
            try budgetAffectedMonth(for: entry, attribution: attribution)
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: transactionStore,
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
        var pendingWrites = additionalWrites
        let receiptAttachment: ReceiptAttachment?
        if let receiptData {
            let createdAttachment = try ReceiptAttachment(
                entryID: entry.id,
                mediaType: .detected(from: receiptData),
                data: receiptData
            )
            receiptAttachment = createdAttachment
            pendingWrites.append(
                try RecordWrite(
                    createdAttachment,
                    id: createdAttachment.id.uuidString,
                    in: .receiptAttachments
                )
            )
        } else {
            receiptAttachment = nil
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
        if let candidateTimeline {
            pendingWrites.append(
                try budgetConfigurationTimelineWrite(candidateTimeline)
            )
        }
        // A capture is represented durably by the SQLCipher draft before it is
        // removed from the redacted inbox. Remove any surviving inbox copy
        // before committing the journal entry: if this fails, the encrypted
        // draft remains retryable; if the process stops afterward, either the
        // draft or the committed journal entry remains, never a promotable
        // duplicate of an already committed transaction.
        if let completedLockedCaptureID {
            guard let currentDraft,
                  currentDraft.sourceCaptureID == completedLockedCaptureID else {
                throw AppModelError.invalidBook
            }
            await pendingDraftWrite?.value
            try await transactionStore.upsert(
                currentDraft,
                id: QuickLogDraft.primaryRecordID,
                in: .quickLogDrafts
            )
            let remainingCaptureCount = try await lockedCaptureStore.remove(
                id: completedLockedCaptureID
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            pendingLockedCaptureCount = remainingCaptureCount
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        }
        let writes = pendingWrites
        let commitTask = Task {
            await pendingDraftWrite?.value
            await lifecycleHooks.checkpoint(.beforeJournalCommit)
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
            try await transactionStore.write(
                writes,
                removing: [
                    RecordDeletion(
                        id: QuickLogDraft.primaryRecordID,
                        from: .quickLogDrafts
                    )
                ]
            )
        }
        let commitID = UUID()
        quickLogCommit = PendingQuickLogCommit(
            id: commitID,
            generation: generation,
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
        guard isCurrentStoreGeneration(generation) else { return nil }
        quickLogDraft = nil
        if !additionalAccounts.isEmpty {
            accounts.append(contentsOf: additionalAccounts)
        }
        if let receiptAttachment {
            receiptAttachmentMetadata.append(ReceiptAttachmentMetadata(receiptAttachment))
        }
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        await refreshJournalAfterMutation()
        if completedLockedCaptureID != nil {
            do {
                try await promoteLockedCaptureIfPossible(
                    to: transactionStore,
                    generation: generation,
                    requestLogRoute: false
                )
            } catch let error as LockedCaptureStoreError {
                recordLockedCaptureStoreIssue(error)
            } catch {
                // The journal entry is already durable. Surface a safe
                // recovery signal instead of reporting Save as failed.
                recordRecoveryIssue("locked_captures/promotion-unavailable")
            }
        }
        return entry.id
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
