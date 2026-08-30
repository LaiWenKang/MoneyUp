import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func reloadPersistedBookForTesting() async throws {
        try await load(from: requireStore())
    }

    /// The journal transaction is already durable when this runs. A compact
    /// refresh failure must make derived UI unavailable and schedule recovery,
    /// not throw a misleading Save error for an operation that did commit.
    func refreshJournalAfterMutation() async {
        journalProjectionRevision &+= 1
        invalidateCommittedJournalProjection()
        if retainsCompleteJournal {
            journalEntryCount = entries.count
            journalStoredEntryCount = entries.count
            journalRecentEntriesAreCurrent = true
            journalDerivedRefreshWasDeferred = false
            refreshBudgetWidgetSnapshot()
            return
        }
        let mutationGeneration = storeGeneration
        do {
            try await refreshJournalDerivedState()
        } catch {
            guard ownsStoreGeneration(mutationGeneration),
                  state == .ready || state == .onboarding else { return }
            balanceCache = .unavailable(.appNotReady)
            reportCache.removeAll()
            reportCacheDay = nil
            monthToDateComparisonCache = nil
            monthToDateComparisonCacheDay = nil
            closedMonthBudgetProjection = nil
            if let refreshStore = store,
               let diagnostics = try? await refreshStore.journalIndexDiagnostics() {
                journalStoredEntryCount = diagnostics.journalRecordCount
            }
            let issue = "journal_entries/derived-refresh-unavailable"
            if !recoveryIssues.contains(issue) { recoveryIssues.append(issue) }
            scheduleJournalDerivedRefresh()
        }
    }

    func load(
        from store: EncryptedRecordStore,
        mode: BookLoadMode = .recovering
    ) async throws {
        journalProjectionRevision &+= 1
        retainsCompleteJournal = false
        invalidateCommittedJournalProjection()
        recoveryIssues = []
        closedMonthBudgetProjection = nil
        budgetConfigurationTimeline = nil
        budgetConfigurationTimelineInvalid = false
        profile = try await store.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        if let profile, mode.updatesPreferences {
            UserDefaults.standard.set(
                profile.allowLockedQuickCapture,
                forKey: Self.lockedQuickCapturePreferenceKey
            )
            // Re-encode on open so legacy profiles persist the inferred
            // opt-out and reporting zone instead of re-inferring after travel.
            try await store.upsert(
                profile,
                id: UserProfile.primaryRecordID,
                in: .profile
            )
        }
        let recoveredAccounts = try await store.fetchAllIdentifiedRecovering(
            LedgerAccount.self,
            from: .accounts
        )
        let recoveredBudgets = try await store.fetchAllIdentifiedRecovering(
            BudgetNode.self,
            from: .budgetNodes
        )
        let recoveredSchedules = try await store.fetchAllIdentifiedRecovering(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        )
        let recoveredHoldings = try await store.fetchAllIdentifiedRecovering(
            InvestmentHolding.self,
            from: .investmentHoldings
        )
        let recoveredAttachments = try await store.receiptAttachmentIndexSnapshot()
        let recoveredRates = try await store.fetchAllIdentifiedRecovering(
            DatedExchangeRate.self,
            from: .exchangeRates
        )
        let recoveredSnapshots = try await store.fetchAllIdentifiedRecovering(
            NetWorthSnapshot.self,
            from: .netWorthSnapshots
        )
        let recoveredGoals = try await store.fetchAllIdentifiedRecovering(
            SavingsGoal.self,
            from: .savingsGoals
        )
        let attributionIndex = try await store.budgetAttributionIndexSnapshot()
        let loadsCompleteBudgetAttributions =
            mode.loadsCompleteBudgetAttributions
            || attributionIndex.requiresDetailedValidation
        let recoveredBudgetAttributions: RecoveredRecords<BudgetEntryAttribution>?
        if loadsCompleteBudgetAttributions {
            recoveredBudgetAttributions = try await store
                .fetchAllIdentifiedRecovering(
                    BudgetEntryAttribution.self,
                    from: .budgetEntryAttributions
                )
        } else {
            recoveredBudgetAttributions = nil
        }
        do {
            budgetConfigurationTimeline = try await store.fetch(
                BudgetConfigurationTimeline.self,
                id: BudgetConfigurationTimeline.primaryRecordID,
                from: .budgetConfigurationTimelines
            )
        } catch {
            budgetConfigurationTimelineInvalid = true
            recoveryIssues.append(
                "budget_configuration_timelines/\(BudgetConfigurationTimeline.primaryRecordID)"
            )
        }
        accounts = try quarantiningDuplicateLogicalIDs(
            recoveredAccounts.values,
            in: .accounts,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        entries = []
        budgetNodes = try quarantiningDuplicateLogicalIDs(
            recoveredBudgets.values,
            in: .budgetNodes,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        scheduledTransactions = try quarantiningDuplicateLogicalIDs(
            recoveredSchedules.values,
            in: .scheduledTransactions,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted {
            $0.nextOccurrence < $1.nextOccurrence
        }
        investmentHoldings = try quarantiningDuplicateLogicalIDs(
            recoveredHoldings.values,
            in: .investmentHoldings,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        receiptAttachmentMetadata = try quarantiningDuplicateLogicalIDs(
            recoveredAttachments.metadata,
            in: .receiptAttachments,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        exchangeRates = try quarantiningDuplicateLogicalIDs(
            recoveredRates.values,
            in: .exchangeRates,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted {
            if $0.effectiveContext.dayKey == $1.effectiveContext.dayKey {
                return $0.createdAt > $1.createdAt
            }
            return $0.effectiveContext.dayKey > $1.effectiveContext.dayKey
        }
        netWorthSnapshots = try quarantiningDuplicateLogicalIDs(
            recoveredSnapshots.values,
            in: .netWorthSnapshots,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted { $0.capturedAt > $1.capturedAt }
        savingsGoals = try quarantiningDuplicateLogicalIDs(
            recoveredGoals.values,
            in: .savingsGoals,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted { $0.targetDate < $1.targetDate }
        budgetEntryAttributions = [:]
        budgetAttributionCacheIsComplete = loadsCompleteBudgetAttributions
        if let recoveredBudgetAttributions {
            let recoveredAttributions = try quarantiningDuplicateLogicalIDs(
                recoveredBudgetAttributions.values,
                in: .budgetEntryAttributions,
                observesCancellation: mode.observesCancellationWhileLoading
            )
            if recoveredAttributions.count
                != recoveredBudgetAttributions.values.count {
                budgetConfigurationTimelineInvalid = true
            }
            for attribution in recoveredAttributions {
                if budgetEntryAttributions.updateValue(
                    attribution,
                    forKey: attribution.id
                ) != nil {
                    budgetConfigurationTimelineInvalid = true
                    recoveryIssues.append(
                        "budget_entry_attributions/duplicate-\(attribution.id)"
                    )
                }
            }
        }
        if attributionIndex.recordCount
                > RestoreCandidateValidator.maximumBudgetAttributionCount
            || attributionIndex.indexedEntryCount != attributionIndex.recordCount
            || attributionIndex.indexedPostingCount
                > RestoreCandidateValidator.maximumJournalPostingCount
            || !attributionIndex.issues.isEmpty
            || !(recoveredBudgetAttributions?.issues.isEmpty ?? true) {
            budgetConfigurationTimelineInvalid = true
            recoveryIssues.append(
                "budget_entry_attributions/inconsistent-index"
            )
        }
        var decodeIssues: [RecordDecodeIssue] = []
        decodeIssues.append(contentsOf: recoveredAccounts.issues)
        decodeIssues.append(contentsOf: recoveredBudgets.issues)
        decodeIssues.append(contentsOf: recoveredSchedules.issues)
        decodeIssues.append(contentsOf: recoveredHoldings.issues)
        decodeIssues.append(contentsOf: recoveredAttachments.issues)
        decodeIssues.append(contentsOf: recoveredRates.issues)
        decodeIssues.append(contentsOf: recoveredSnapshots.issues)
        decodeIssues.append(contentsOf: recoveredGoals.issues)
        decodeIssues.append(contentsOf: attributionIndex.issues)
        decodeIssues.append(contentsOf: recoveredBudgetAttributions?.issues ?? [])
        recoveryIssues.append(contentsOf: decodeIssues.map {
            "\($0.collection.rawValue)/\($0.recordID)"
        })
        let existingAttachmentEntryIDs = try await store.existingJournalEntryIDs(
            in: Set(receiptAttachmentMetadata.map(\.entryID))
        )
        let scheduledLinkedEntryIDs = Set(
            scheduledTransactions.flatMap(\.resolutions).compactMap(\.linkedEntryID)
        )
        let existingScheduledEntryIDs = try await store.existingJournalEntryIDs(
            in: scheduledLinkedEntryIDs
        )
        let existingBudgetAttributionEntryIDs: Set<UUID>?
        if loadsCompleteBudgetAttributions {
            existingBudgetAttributionEntryIDs = try await store
                .existingJournalEntryIDs(
                    in: Set(budgetEntryAttributions.keys)
                )
        } else {
            existingBudgetAttributionEntryIDs = nil
        }
        existingScheduledLinkedEntryIDs = existingScheduledEntryIDs
        let requestedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        var investmentEntriesByID: [UUID: JournalEntry] = [:]
        for entryID in requestedInvestmentEntryIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            if mode.observesCancellationWhileLoading {
                try Task.checkCancellation()
            }
            do {
                if let entry = try await store.fetch(
                    JournalEntry.self,
                    id: entryID.uuidString,
                    from: .journalEntries
                ) {
                    investmentEntriesByID[entryID] = entry
                } else {
                    recoveryIssues.append("journal_entries/missing-investment-link")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recoveryIssues.append("journal_entries/unreadable-investment-link")
            }
        }
        investmentLinkedEntriesByID = investmentEntriesByID
        try quarantineInvalidRelationships(
            existingAttachmentEntryIDs: existingAttachmentEntryIDs,
            existingScheduledEntryIDs: existingScheduledEntryIDs,
            existingBudgetAttributionEntryIDs: existingBudgetAttributionEntryIDs,
            investmentEntriesByID: investmentEntriesByID,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        if loadsCompleteBudgetAttributions {
            try await validateBudgetEntryAttributionsAfterLoad(in: store)
        }
        // Rollover's complete closed-month projection depends on the persisted
        // dated configuration. Prepare or quarantine that timeline before the
        // normalized journal refresh derives any budget state from it.
        try await prepareBudgetConfigurationTimelineAfterLoad(
            in: store,
            persistsMigration: mode.persistsBudgetTimelineMigration
        )
        try await refreshJournalDerivedState(
            from: store,
            loadRecentEntries: true,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        if !mode.rejectsRecoveryIssues,
           quarantineInvestmentLedgerMismatches() {
            try await refreshJournalDerivedState(
                from: store,
                loadRecentEntries: true,
                observesCancellation: mode.observesCancellationWhileLoading
            )
        }
        // The normalized ledger snapshot identifies entries that exist but are
        // quarantined as one atomic unit because an account reference is bad.
        // Their attachments remain preserved in SQLCipher/backups but hidden
        // from the live book with the entry itself.
        receiptAttachmentMetadata.removeAll { attachment in
            let invalid = invalidJournalEntryIDs.contains(attachment.entryID)
            if invalid {
                recoveryIssues.append("receipt_attachments/orphan-\(attachment.id)")
            }
            return invalid
        }
        do {
            quickLogDraft = try await store.fetch(
                QuickLogDraft.self,
                id: QuickLogDraft.primaryRecordID,
                from: .quickLogDrafts
            )
        } catch {
            if mode.rejectsRecoveryIssues {
                throw AppModelError.invalidBook
            }
            // A malformed convenience draft should not lock the user out of
            // the valid encrypted book. Discard it and continue opening.
            quickLogDraft = nil
            if mode.removesMalformedDraft {
                try? await store.remove(
                    id: QuickLogDraft.primaryRecordID,
                    from: .quickLogDrafts
                )
            }
        }
        try await persistCurrentMonthBudgetCheckpointIfNeeded(
            in: store,
            persistsCheckpoint: mode.persistsBudgetTimelineMigration
        )
        if mode.rejectsRecoveryIssues, !recoveryIssues.isEmpty {
            throw AppModelError.invalidBook
        }
    }
}
