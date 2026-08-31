import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

struct AppModelRecoveredBookRecords: Sendable {
    let accounts: RecoveredRecords<LedgerAccount>
    let budgets: RecoveredRecords<BudgetNode>
    let schedules: RecoveredRecords<ScheduledTransaction>
    let holdings: RecoveredRecords<InvestmentHolding>
    let attachments: ReceiptAttachmentIndexSnapshot
    let rates: RecoveredRecords<DatedExchangeRate>
    let snapshots: RecoveredRecords<NetWorthSnapshot>
    let goals: RecoveredRecords<SavingsGoal>
    let attributionIndex: BudgetAttributionIndexSnapshot
    let budgetAttributions: RecoveredRecords<BudgetEntryAttribution>?
    let loadsCompleteBudgetAttributions: Bool
}

struct AppModelRecoveryRelationships: Sendable {
    let attachmentEntryIDs: Set<UUID>
    let scheduledEntryIDs: Set<UUID>
    let budgetAttributionEntryIDs: Set<UUID>?
    let investmentEntriesByID: [UUID: JournalEntry]
    let loadsCompleteBudgetAttributions: Bool
}

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
        prepareBookLoadState()
        try await loadRecoveryProfile(from: store, mode: mode)
        let recovered = try await fetchRecoveredBookRecords(
            from: store,
            mode: mode
        )
        await loadBudgetConfigurationTimeline(from: store)
        try applyRecoveredBookRecords(recovered, mode: mode)
        let relationships = try await loadRecoveryRelationships(
            from: store,
            loadsCompleteBudgetAttributions:
                recovered.loadsCompleteBudgetAttributions,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        try await reconcileRecoveredRelationships(
            relationships,
            in: store,
            mode: mode
        )
        try await loadQuickLogDraft(from: store, mode: mode)
        try await persistCurrentMonthBudgetCheckpointIfNeeded(
            in: store,
            persistsCheckpoint: mode.persistsBudgetTimelineMigration
        )
        if mode.rejectsRecoveryIssues, !recoveryIssues.isEmpty {
            throw AppModelError.invalidBook
        }
    }

    func prepareBookLoadState() {
        journalProjectionRevision &+= 1
        retainsCompleteJournal = false
        invalidateCommittedJournalProjection()
        recoveryIssues = []
        closedMonthBudgetProjection = nil
        budgetConfigurationTimeline = nil
        budgetConfigurationTimelineInvalid = false
    }

    func loadRecoveryProfile(
        from store: EncryptedRecordStore,
        mode: BookLoadMode
    ) async throws {
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
    }

    func fetchRecoveredBookRecords(
        from store: EncryptedRecordStore,
        mode: BookLoadMode
    ) async throws -> AppModelRecoveredBookRecords {
        let accounts = try await store.fetchAllIdentifiedRecovering(
            LedgerAccount.self,
            from: .accounts
        )
        let budgets = try await store.fetchAllIdentifiedRecovering(
            BudgetNode.self,
            from: .budgetNodes
        )
        let schedules = try await store.fetchAllIdentifiedRecovering(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        )
        let holdings = try await store.fetchAllIdentifiedRecovering(
            InvestmentHolding.self,
            from: .investmentHoldings
        )
        let attachments = try await store.receiptAttachmentIndexSnapshot()
        let rates = try await store.fetchAllIdentifiedRecovering(
            DatedExchangeRate.self,
            from: .exchangeRates
        )
        let snapshots = try await store.fetchAllIdentifiedRecovering(
            NetWorthSnapshot.self,
            from: .netWorthSnapshots
        )
        let goals = try await store.fetchAllIdentifiedRecovering(
            SavingsGoal.self,
            from: .savingsGoals
        )
        let attributionIndex = try await store.budgetAttributionIndexSnapshot()
        let loadsCompleteBudgetAttributions =
            mode.loadsCompleteBudgetAttributions
            || attributionIndex.requiresDetailedValidation
        let budgetAttributions: RecoveredRecords<BudgetEntryAttribution>?
        if loadsCompleteBudgetAttributions {
            budgetAttributions = try await store
                .fetchAllIdentifiedRecovering(
                    BudgetEntryAttribution.self,
                    from: .budgetEntryAttributions
                )
        } else {
            budgetAttributions = nil
        }
        return AppModelRecoveredBookRecords(
            accounts: accounts,
            budgets: budgets,
            schedules: schedules,
            holdings: holdings,
            attachments: attachments,
            rates: rates,
            snapshots: snapshots,
            goals: goals,
            attributionIndex: attributionIndex,
            budgetAttributions: budgetAttributions,
            loadsCompleteBudgetAttributions: loadsCompleteBudgetAttributions
        )
    }

    func loadBudgetConfigurationTimeline(
        from store: EncryptedRecordStore
    ) async {
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
    }

    func applyRecoveredBookRecords(
        _ recovered: AppModelRecoveredBookRecords,
        mode: BookLoadMode
    ) throws {
        try applyRecoveredLedgerRecords(recovered, mode: mode)
        try applyRecoveredSupportingRecords(recovered, mode: mode)
        try applyRecoveredBudgetAttributions(recovered, mode: mode)
        appendRecoveryDecodeIssues(from: recovered)
    }

    func applyRecoveredLedgerRecords(
        _ recovered: AppModelRecoveredBookRecords,
        mode: BookLoadMode
    ) throws {
        accounts = try quarantiningDuplicateLogicalIDs(
            recovered.accounts.values,
            in: .accounts,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        entries = []
        budgetNodes = try quarantiningDuplicateLogicalIDs(
            recovered.budgets.values,
            in: .budgetNodes,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        scheduledTransactions = try quarantiningDuplicateLogicalIDs(
            recovered.schedules.values,
            in: .scheduledTransactions,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted {
            $0.nextOccurrence < $1.nextOccurrence
        }
        investmentHoldings = try quarantiningDuplicateLogicalIDs(
            recovered.holdings.values,
            in: .investmentHoldings,
            observesCancellation: mode.observesCancellationWhileLoading
        )
    }

    func applyRecoveredSupportingRecords(
        _ recovered: AppModelRecoveredBookRecords,
        mode: BookLoadMode
    ) throws {
        receiptAttachmentMetadata = try quarantiningDuplicateLogicalIDs(
            recovered.attachments.metadata,
            in: .receiptAttachments,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        exchangeRates = try quarantiningDuplicateLogicalIDs(
            recovered.rates.values,
            in: .exchangeRates,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted {
            if $0.effectiveContext.dayKey == $1.effectiveContext.dayKey {
                return $0.createdAt > $1.createdAt
            }
            return $0.effectiveContext.dayKey > $1.effectiveContext.dayKey
        }
        netWorthSnapshots = try quarantiningDuplicateLogicalIDs(
            recovered.snapshots.values,
            in: .netWorthSnapshots,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted { $0.capturedAt > $1.capturedAt }
        savingsGoals = try quarantiningDuplicateLogicalIDs(
            recovered.goals.values,
            in: .savingsGoals,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted { $0.targetDate < $1.targetDate }
    }

    func applyRecoveredBudgetAttributions(
        _ recovered: AppModelRecoveredBookRecords,
        mode: BookLoadMode
    ) throws {
        budgetEntryAttributions = [:]
        budgetAttributionCacheIsComplete =
            recovered.loadsCompleteBudgetAttributions
        if let recoveredBudgetAttributions = recovered.budgetAttributions {
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
        if recovered.attributionIndex.recordCount
                > RestoreCandidateValidator.maximumBudgetAttributionCount
            || recovered.attributionIndex.indexedEntryCount
                != recovered.attributionIndex.recordCount
            || recovered.attributionIndex.indexedPostingCount
                > RestoreCandidateValidator.maximumJournalPostingCount
            || !recovered.attributionIndex.issues.isEmpty
            || !(recovered.budgetAttributions?.issues.isEmpty ?? true) {
            budgetConfigurationTimelineInvalid = true
            recoveryIssues.append(
                "budget_entry_attributions/inconsistent-index"
            )
        }
    }

    func appendRecoveryDecodeIssues(
        from recovered: AppModelRecoveredBookRecords
    ) {
        var decodeIssues: [RecordDecodeIssue] = []
        decodeIssues.append(contentsOf: recovered.accounts.issues)
        decodeIssues.append(contentsOf: recovered.budgets.issues)
        decodeIssues.append(contentsOf: recovered.schedules.issues)
        decodeIssues.append(contentsOf: recovered.holdings.issues)
        decodeIssues.append(contentsOf: recovered.attachments.issues)
        decodeIssues.append(contentsOf: recovered.rates.issues)
        decodeIssues.append(contentsOf: recovered.snapshots.issues)
        decodeIssues.append(contentsOf: recovered.goals.issues)
        decodeIssues.append(contentsOf: recovered.attributionIndex.issues)
        decodeIssues.append(contentsOf: recovered.budgetAttributions?.issues ?? [])
        recoveryIssues.append(contentsOf: decodeIssues.map {
            "\($0.collection.rawValue)/\($0.recordID)"
        })
    }

    func loadRecoveryRelationships(
        from store: EncryptedRecordStore,
        loadsCompleteBudgetAttributions: Bool,
        observesCancellation: Bool
    ) async throws -> AppModelRecoveryRelationships {
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
        let investmentEntriesByID = try await loadRecoveryInvestmentEntries(
            from: store,
            observesCancellation: observesCancellation
        )
        investmentLinkedEntriesByID = investmentEntriesByID
        return AppModelRecoveryRelationships(
            attachmentEntryIDs: existingAttachmentEntryIDs,
            scheduledEntryIDs: existingScheduledEntryIDs,
            budgetAttributionEntryIDs: existingBudgetAttributionEntryIDs,
            investmentEntriesByID: investmentEntriesByID,
            loadsCompleteBudgetAttributions: loadsCompleteBudgetAttributions
        )
    }

    func loadRecoveryInvestmentEntries(
        from store: EncryptedRecordStore,
        observesCancellation: Bool
    ) async throws -> [UUID: JournalEntry] {
        let requestedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        var investmentEntriesByID: [UUID: JournalEntry] = [:]
        for entryID in requestedInvestmentEntryIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            if observesCancellation {
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
        return investmentEntriesByID
    }

    func reconcileRecoveredRelationships(
        _ relationships: AppModelRecoveryRelationships,
        in store: EncryptedRecordStore,
        mode: BookLoadMode
    ) async throws {
        try quarantineInvalidRelationships(
            existingAttachmentEntryIDs: relationships.attachmentEntryIDs,
            existingScheduledEntryIDs: relationships.scheduledEntryIDs,
            existingBudgetAttributionEntryIDs:
                relationships.budgetAttributionEntryIDs,
            investmentEntriesByID: relationships.investmentEntriesByID,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        if relationships.loadsCompleteBudgetAttributions {
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
    }

    func loadQuickLogDraft(
        from store: EncryptedRecordStore,
        mode: BookLoadMode
    ) async throws {
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
    }
}
