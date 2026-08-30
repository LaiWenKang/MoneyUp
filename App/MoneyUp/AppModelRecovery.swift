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

    func promotePendingLockedCapture() async throws {
        try beginLockedCapturePromotion()
        defer { endLockedCapturePromotion() }
        let generation = storeGeneration
        let currentStore = try requireStore()
        try await promoteLockedCaptureIfPossible(
            to: currentStore,
            generation: generation
        )
    }

    func beginLockedCapturePromotion() throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        lockedCapturePromotionInProgress = true
    }

    func endLockedCapturePromotion() {
        lockedCapturePromotionInProgress = false
        applyDeferredLockIfPossible()
    }

    static func lockedCaptureFingerprint(_ id: UUID) -> String {
        "locked-capture:\(id.uuidString.lowercased())"
    }

    func promoteLockedCaptureIfPossible(
        to store: EncryptedRecordStore,
        generation: Int,
        requestLogRoute: Bool = true
    ) async throws {
        var captures = try await lockedCaptureStore.all()
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = captures.count

        if let sourceID = quickLogDraft?.sourceCaptureID {
            let remainingCaptureCount = try await lockedCaptureStore.remove(id: sourceID)
            guard ownsStoreGeneration(generation) else { return }
            pendingLockedCaptureCount = remainingCaptureCount
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }
        guard quickLogDraft == nil else {
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }

        while let replay = captures.first,
              try await store.containsJournalEntry(
                sourceFingerprint: Self.lockedCaptureFingerprint(replay.id)
              ) {
            pendingLockedCaptureCount = try await lockedCaptureStore.remove(
                id: replay.id
            )
            captures.removeFirst()
            guard ownsStoreGeneration(generation) else { return }
        }
        guard let capture = captures.first else {
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }

        let kind: QuickLogKind
        let mode: QuickLogLaunchMode
        switch capture.kind {
        case .income:
            kind = .income
            mode = .income
        case .transfer:
            kind = .transfer
            mode = .transfer
        case .expense:
            kind = .expense
            mode = .expense
        case .refund:
            kind = .refund
            mode = .refund
        }
        let draft = QuickLogDraft(
            kind: kind,
            amountText: capture.amountText,
            destinationAmountText: "",
            accountID: nil,
            destinationAccountID: nil,
            categoryID: nil,
            occurredAt: capture.occurredAt,
            dateWasEdited: true,
            payee: capture.payee,
            note: capture.note,
            smartText: "",
            sourceCaptureID: capture.id
        )
        try await store.upsert(
            draft,
            id: QuickLogDraft.primaryRecordID,
            in: .quickLogDrafts
        )
        await lifecycleHooks.checkpoint(.afterCaptureDraftPersisted)
        guard ownsStoreGeneration(generation) else { return }
        quickLogDraft = draft
        let remainingCaptureCount = try await lockedCaptureStore.remove(id: capture.id)
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = remainingCaptureCount
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        if requestLogRoute { requestedQuickLogMode = mode }
    }

    func recordRecoveryIssue(_ issue: String) {
        guard !recoveryIssues.contains(issue) else { return }
        recoveryIssues.append(issue)
    }

    func recordLockedCaptureStoreIssue(
        _ error: LockedCaptureStoreError
    ) {
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        let suffix = error.isDefinitivelyUnrecoverable
            ? "unrecoverable"
            : "unavailable"
        recordRecoveryIssue("locked_captures/\(suffix)")
    }

    /// Classifies each account hierarchy once. A root-to-leaf walk for every
    /// account is quadratic for a deep but otherwise valid hierarchy and can
    /// make opening an authenticated archive appear to hang. Invalidity is
    /// inherited by descendants, so missing parents, kind mismatches, and
    /// every member/descendant of a cycle are quarantined together.
    nonisolated static func invalidAccountHierarchyIDs(
        in accounts: [LedgerAccount],
        observesCancellation: Bool = true
    ) throws -> Set<UUID> {
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        // 1 = active path, 2 = resolves to a valid root, 3 = invalid.
        var resolutionByID: [UUID: UInt8] = [:]
        resolutionByID.reserveCapacity(accountByID.count)
        var inspectedCount = 0

        for account in accounts where resolutionByID[account.id] == nil {
            var path: [UUID] = []
            var currentID: UUID? = account.id
            var resolvesToValidRoot = true

            while let id = currentID {
                if observesCancellation,
                   inspectedCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                inspectedCount += 1

                switch resolutionByID[id] {
                case 1:
                    resolvesToValidRoot = false
                    currentID = nil
                    continue
                case 2:
                    resolvesToValidRoot = true
                    currentID = nil
                    continue
                case 3:
                    resolvesToValidRoot = false
                    currentID = nil
                    continue
                default:
                    break
                }

                guard let current = accountByID[id] else {
                    resolvesToValidRoot = false
                    break
                }
                resolutionByID[id] = 1
                path.append(id)

                guard let parentID = current.parentID else {
                    resolvesToValidRoot = true
                    break
                }
                guard let parent = accountByID[parentID],
                      parent.kind == current.kind else {
                    resolvesToValidRoot = false
                    break
                }
                currentID = parentID
            }

            let resolution: UInt8 = resolvesToValidRoot ? 2 : 3
            for id in path {
                resolutionByID[id] = resolution
            }
        }

        return Set(resolutionByID.compactMap { item in
            item.value == 3 ? item.key : nil
        })
    }

    /// Rejects logical identity ambiguity without deleting forensic/recovery
    /// evidence from the encrypted store.
    func quarantiningDuplicateLogicalIDs<Value: Identifiable>(
        _ values: [Value],
        in collection: RecordCollection,
        observesCancellation: Bool
    ) throws -> [Value] where Value.ID == UUID {
        var identityCounts: [UUID: Int] = [:]
        for (offset, value) in values.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            identityCounts[value.id, default: 0] += 1
        }
        let duplicateIDs = Set(identityCounts.compactMap {
            $0.value > 1 ? $0.key : nil
        })
        guard !duplicateIDs.isEmpty else { return values }

        recoveryIssues.append(contentsOf: duplicateIDs.sorted {
            $0.uuidString < $1.uuidString
        }.map {
            "\(collection.rawValue)/duplicate-\($0)"
        })
        // Physical record keys are not exposed by decoded domain values.
        // Keeping an arbitrary winner would let another physical row restore
        // stale data after a canonical update/delete. Preserve every encrypted
        // row for recovery, but expose none of the ambiguous logical values.
        return values.filter { !duplicateIDs.contains($0.id) }
    }

    /// Invalid rows remain untouched in SQLCipher and in portable backups, but
    /// are excluded from calculations until repaired. This keeps one orphan
    /// from turning the entire otherwise-readable book into an erase screen.
    func quarantineInvalidRelationships(
        existingAttachmentEntryIDs: Set<UUID>? = nil,
        existingScheduledEntryIDs: Set<UUID>? = nil,
        existingBudgetAttributionEntryIDs: Set<UUID>? = nil,
        investmentEntriesByID: [UUID: JournalEntry] = [:],
        observesCancellation: Bool
    ) throws {
        let invalidHierarchyIDs = try Self.invalidAccountHierarchyIDs(
            in: accounts,
            observesCancellation: observesCancellation
        )
        if !invalidHierarchyIDs.isEmpty {
            recoveryIssues.append(contentsOf: invalidHierarchyIDs.map {
                "accounts/orphan-or-cycle-\($0)"
            })
            accounts.removeAll { invalidHierarchyIDs.contains($0.id) }
        }
        var accountIDs = Set(accounts.map(\.id))
        let retainedAccountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )

        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        let invalidBudgetIDs = Set(budgetNodes.filter {
            !expenseIDs.contains($0.id)
                || ($0.parentID.map { !expenseIDs.contains($0) } ?? false)
        }.map(\.id))
        if !invalidBudgetIDs.isEmpty {
            recoveryIssues.append(contentsOf: invalidBudgetIDs.map { "budgets/orphan-\($0)" })
            budgetNodes.removeAll { invalidBudgetIDs.contains($0.id) }
        }
        if let currency = profile?.baseCurrency,
           (try? BudgetTree(currency: currency, nodes: budgetNodes)) == nil,
           !budgetNodes.isEmpty {
            recoveryIssues.append("budgets/invalid-tree")
            budgetNodes = []
        }

        entries.removeAll { entry in
            let invalid = entry.postings.contains { !accountIDs.contains($0.accountID) }
            if invalid { recoveryIssues.append("journal_entries/orphan-\(entry.id)") }
            return invalid
        }
        var scheduleLinkOwners: [UUID: Set<UUID>] = [:]
        for schedule in scheduledTransactions {
            for entryID in schedule.resolutions.compactMap(\.linkedEntryID) {
                scheduleLinkOwners[entryID, default: []].insert(schedule.id)
            }
        }
        let reusedScheduleEntryIDs = Set(
            scheduleLinkOwners.filter { $0.value.count > 1 }.keys
        )
        let entryIDs = Set(entries.map(\.id))
        budgetEntryAttributions = budgetEntryAttributions.filter { item in
            let valid = existingBudgetAttributionEntryIDs?.contains(item.key)
                ?? entryIDs.contains(item.key)
            if !valid {
                recoveryIssues.append(
                    "budget_entry_attributions/orphan-\(item.key)"
                )
            }
            return valid
        }
        try scheduledTransactions.removeAll { item in
            let linkedEntryIDs = Set(item.resolutions.compactMap(\.linkedEntryID))
            let invalidLifecycle: Bool
            do {
                try item.validateLifecycle(calendar: reportingCalendar)
                invalidLifecycle = false
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                invalidLifecycle = true
            }
            let invalid = !accountIDs.contains(item.accountID)
                || !accountIDs.contains(item.categoryAccountID)
                || invalidLifecycle
                || !linkedEntryIDs.isDisjoint(with: reusedScheduleEntryIDs)
                || existingScheduledEntryIDs.map {
                    !linkedEntryIDs.isSubset(of: $0)
                } == true
            if invalid { recoveryIssues.append("scheduled_transactions/orphan-\(item.id)") }
            return invalid
        }
        let duplicateHoldingIDs = Set(
            Dictionary(grouping: investmentHoldings, by: \.id)
                .filter { $0.value.count > 1 }
                .keys
        )
        let duplicatePositionIDs = Set(
            Dictionary(
                grouping: investmentHoldings.compactMap(\.positionAccountID),
                by: { $0 }
            )
            .filter { $0.value.count > 1 }
            .keys
        )
        var entryOwners: [UUID: Set<UUID>] = [:]
        for holding in investmentHoldings {
            for entryID in holding.linkedEntryIDs {
                entryOwners[entryID, default: []].insert(holding.id)
            }
        }
        let reusedEntryIDs = Set(entryOwners.filter { $0.value.count > 1 }.keys)
        try investmentHoldings.removeAll { holding in
            let funding = retainedAccountByID[holding.accountID]
            let position = holding.positionAccountID.flatMap { id in
                retainedAccountByID[id]
            }
            let holdingCurrencies = Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
            let invalidFunding = funding.map {
                !isInvestmentFundingAccountShape($0)
                    || (!holding.isArchived && $0.isArchived)
            } ?? true
            let invalidPosition: Bool
            if let positionID = holding.positionAccountID {
                invalidPosition = positionID == holding.accountID
                    || position?.systemRole != .investmentPosition
                    || position?.kind != .asset
                    || position?.currency != funding?.currency
                    || position?.isArchived != holding.isArchived
            } else {
                invalidPosition = holding.isArchived
                    || !holding.linkedEntryIDs.isEmpty
                    || !(holding.quantity == .zero || holding.needsLedgerConnection)
            }
            let invalidLinks: Bool
            if holding.positionAccountID != nil {
                do {
                    try InvestmentLedgerIntegrity.validate(
                        holding: holding,
                        accountsByID: retainedAccountByID,
                        entriesByID: investmentEntriesByID
                    )
                    invalidLinks = false
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    invalidLinks = true
                }
            } else {
                invalidLinks = !holding.linkedEntryIDs.isEmpty
            }
            let invalid = duplicateHoldingIDs.contains(holding.id)
                || holding.positionAccountID.map(duplicatePositionIDs.contains) == true
                || !holding.linkedEntryIDs.isDisjoint(with: reusedEntryIDs)
                || invalidFunding
                || holdingCurrencies.contains { $0 != funding?.currency }
                || invalidPosition
                || invalidLinks
            if invalid { recoveryIssues.append("investment_holdings/orphan-\(holding.id)") }
            return invalid
        }
        let retainedPositionIDs = Set(investmentHoldings.compactMap(\.positionAccountID))
        let activeOrphanPositionIDs = Set(accounts.compactMap { account -> UUID? in
            guard account.systemRole == .investmentPosition,
                  !account.isArchived,
                  !retainedPositionIDs.contains(account.id) else { return nil }
            return account.id
        })
        if !activeOrphanPositionIDs.isEmpty {
            recoveryIssues.append(contentsOf: activeOrphanPositionIDs.map {
                "accounts/orphan-investment-position-\($0)"
            })
            accounts.removeAll { activeOrphanPositionIDs.contains($0.id) }
            accountIDs.subtract(activeOrphanPositionIDs)
            entries.removeAll { entry in
                entry.postings.contains {
                    activeOrphanPositionIDs.contains($0.accountID)
                }
            }
            scheduledTransactions.removeAll { schedule in
                activeOrphanPositionIDs.contains(schedule.accountID)
                    || activeOrphanPositionIDs.contains(
                        schedule.categoryAccountID
                    )
            }
        }
        let retainedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        investmentLinkedEntriesByID = investmentLinkedEntriesByID.filter {
            retainedInvestmentEntryIDs.contains($0.key)
        }
        let attachmentEntryIDs = existingAttachmentEntryIDs
            ?? Set(entries.map(\.id))
        var seenAttachmentIDs = Set<UUID>()
        receiptAttachmentMetadata.removeAll { attachment in
            let duplicate = !seenAttachmentIDs.insert(attachment.id).inserted
            let invalid = duplicate
                || !attachmentEntryIDs.contains(attachment.entryID)
            if duplicate {
                recoveryIssues.append("receipt_attachments/duplicate-\(attachment.id)")
            } else if invalid {
                recoveryIssues.append("receipt_attachments/orphan-\(attachment.id)")
            }
            return invalid
        }
        var seenGoalIDs = Set<UUID>()
        savingsGoals = savingsGoals.filter { goal in
            let unique = seenGoalIDs.insert(goal.id).inserted
            if !unique { recoveryIssues.append("savings_goals/duplicate-\(goal.id)") }
            return unique
        }
    }

    /// Normal unlock keeps the rest of a readable book available when a
    /// holding's reconstructed market value disagrees with its ledger account.
    /// Restore validation deliberately skips this repair and rejects instead.
    @discardableResult
    func quarantineInvestmentLedgerMismatches() -> Bool {
        guard case let .available(balances) = accountBalancesResult() else {
            return false
        }
        var invalidHoldingIDs = Set<UUID>()
        var invalidPositionIDs = Set<UUID>()
        for holding in investmentHoldings {
            guard let positionID = holding.positionAccountID,
                  let funding = accountsByID[holding.accountID],
                  let currency = funding.currency else { continue }
            let expected: Money
            do {
                expected = try holding.marketValue()
                    ?? Money.zero(currency: currency)
            } catch {
                invalidHoldingIDs.insert(holding.id)
                invalidPositionIDs.insert(positionID)
                continue
            }
            let positionBalances = balances[positionID] ?? [:]
            let hasForeignBalance = positionBalances.contains {
                $0.key != currency && !$0.value.isZero
            }
            let actual = positionBalances[currency]
                ?? Money.zero(currency: currency)
            if hasForeignBalance || actual != expected {
                invalidHoldingIDs.insert(holding.id)
                invalidPositionIDs.insert(positionID)
            }
        }
        if !invalidHoldingIDs.isEmpty {
            recoveryIssues.append("investment_holdings/ledger-mismatch")
            investmentHoldings.removeAll { invalidHoldingIDs.contains($0.id) }
        }

        let retainedPositionIDs = Set(investmentHoldings.compactMap(\.positionAccountID))
        for position in accounts where position.systemRole == .investmentPosition
            && !retainedPositionIDs.contains(position.id) {
            let positionBalances = balances[position.id] ?? [:]
            if !position.isArchived
                || positionBalances.values.contains(where: { !$0.isZero }) {
                invalidPositionIDs.insert(position.id)
            }
        }
        guard !invalidPositionIDs.isEmpty else { return false }
        if !recoveryIssues.contains("accounts/orphan-investment-position") {
            recoveryIssues.append("accounts/orphan-investment-position")
        }
        accounts.removeAll { invalidPositionIDs.contains($0.id) }
        scheduledTransactions.removeAll { schedule in
            invalidPositionIDs.contains(schedule.accountID)
                || invalidPositionIDs.contains(schedule.categoryAccountID)
        }
        let retainedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        investmentLinkedEntriesByID = investmentLinkedEntriesByID.filter {
            retainedInvestmentEntryIDs.contains($0.key)
        }
        existingScheduledLinkedEntryIDs = Set(
            scheduledTransactions.flatMap(\.resolutions).compactMap(\.linkedEntryID)
        )
        return true
    }

    func reassignAndDeleteLedgerItem(
        id sourceID: UUID,
        to targetID: UUID,
        action: LedgerAccountLifecycleAction
    ) async throws {
        await finishPendingQuickLogDraftWrite()
        guard let source = accounts.first(where: { $0.id == sourceID }),
              let target = accounts.first(where: { $0.id == targetID }) else {
            throw AppModelError.missingRecord
        }
        try requireLifecycleEligible(source)
        try requireLifecycleEligible(target)
        guard sourceID != targetID else { throw AppModelError.incompatibleLedgerItems }
        guard !target.isArchived,
              source.kind == target.kind,
              source.currency == target.currency else {
            throw AppModelError.incompatibleLedgerItems
        }
        if investmentHoldings.contains(where: {
            $0.accountID == sourceID && $0.positionAccountID != nil
        }),
           !isInvestmentFundingAccountShape(target) {
            throw AppModelError.incompatibleLedgerItems
        }

        let candidateAccounts = try accountsAfterReassigningCategoryHierarchy(
            source: source,
            target: target
        )
        let candidateBudgets = try budgetsAfterReassigningCategoryHierarchy(
            source: source,
            target: target,
            candidateAccounts: candidateAccounts
        )
        let candidateTimeline: BudgetConfigurationTimeline?
        if source.kind == .expense {
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets,
                carryMappings: [BudgetCarryMapping(
                    sourceID: sourceID,
                    targetID: targetID
                )]
            )
        } else {
            candidateTimeline = nil
        }

        let sourceEntries: [JournalEntry]
        if retainsCompleteJournal {
            sourceEntries = entries
        } else {
            // Account merge/delete is explicitly confirmed and may touch every
            // historical row. Page it on demand, commit all replacements in
            // one SQLCipher transaction, then release this temporary array.
            sourceEntries = try await journalSnapshot(
                includeInvalidRelationships: true
            )
        }
        var originalEntriesByID: [UUID: JournalEntry] = [:]
        let candidateEntries = try sourceEntries.map { entry in
            guard entry.postings.contains(where: { $0.accountID == sourceID }) else {
                return entry
            }
            originalEntriesByID[entry.id] = entry
            return try repoint(entry: entry, from: sourceID, to: targetID)
        }
        let lifecycleStore = try requireStore()
        if source.kind == .expense {
            try await loadCompleteBudgetAttributionCacheIfNeeded(
                from: lifecycleStore
            )
        }
        var candidateBudgetAttributions = budgetEntryAttributions
        var newBudgetAttributions: [BudgetEntryAttribution] = []
        if source.kind == .expense {
            for original in originalEntriesByID.values
            where candidateBudgetAttributions[original.id] == nil {
                let attribution = try BudgetEntryAttribution(
                    entry: original,
                    originTimeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                        ?? reportingCalendar.timeZone.identifier
                )
                candidateBudgetAttributions[original.id] = attribution
                newBudgetAttributions.append(attribution)
            }
        }

        var changedScheduleIDs = Set<UUID>()
        let candidateSchedules = scheduledTransactions.map { schedule -> ScheduledTransaction in
            var updated = schedule
            if updated.accountID == sourceID {
                updated.accountID = targetID
                changedScheduleIDs.insert(updated.id)
            }
            if updated.categoryAccountID == sourceID {
                updated.categoryAccountID = targetID
                changedScheduleIDs.insert(updated.id)
            }
            return updated
        }

        var changedHoldingIDs = Set<UUID>()
        let candidateHoldings = investmentHoldings.map { holding -> InvestmentHolding in
            var updated = holding
            if updated.accountID == sourceID {
                updated.accountID = targetID
                changedHoldingIDs.insert(updated.id)
            }
            return updated
        }

        try validateLifecycleRelationshipCandidates(
            accounts: candidateAccounts,
            entries: candidateEntries,
            schedules: candidateSchedules,
            holdings: candidateHoldings
        )

        var candidateProfile = profile
        var candidateDraft = quickLogDraft
        repointReferences(from: sourceID, to: targetID, in: &candidateProfile)
        repointReferences(from: sourceID, to: targetID, in: &candidateDraft)

        guard let resultingTarget = candidateAccounts.first(where: { $0.id == targetID }) else {
            throw AppModelError.invalidBook
        }
        let audit = LedgerAccountLifecycleAudit(
            action: action,
            before: source,
            after: resultingTarget,
            targetID: targetID,
            beforeBudget: budgetNodes.first { $0.id == sourceID },
            afterBudget: candidateBudgets.first { $0.id == targetID },
            affectedJournalEntryIDs: Array(originalEntriesByID.keys),
            affectedScheduleIDs: Array(changedScheduleIDs),
            affectedHoldingIDs: Array(changedHoldingIDs)
        )

        var writes: [RecordWrite] = []
        let originalAccountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for account in candidateAccounts
        where originalAccountsByID[account.id] != account {
            writes.append(
                try RecordWrite(account, id: account.id.uuidString, in: .accounts)
            )
        }

        for entry in candidateEntries where originalEntriesByID[entry.id] != nil {
            guard let original = originalEntriesByID[entry.id] else { continue }
            writes.append(
                try RecordWrite(
                    original,
                    id: "\(original.id.uuidString)-lifecycle-\(audit.id.uuidString)",
                    in: .journalEntryRevisions
                )
            )
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
        }
        writes += try newBudgetAttributions.map {
            try RecordWrite(
                $0,
                id: $0.id.uuidString,
                in: .budgetEntryAttributions
            )
        }

        let originalBudgetsByID = Dictionary(uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) })
        for node in candidateBudgets where originalBudgetsByID[node.id] != node {
            writes.append(try RecordWrite(node, id: node.id.uuidString, in: .budgetNodes))
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        for schedule in candidateSchedules where changedScheduleIDs.contains(schedule.id) {
            writes.append(
                try RecordWrite(
                    schedule,
                    id: schedule.id.uuidString,
                    in: .scheduledTransactions
                )
            )
        }
        for holding in candidateHoldings where changedHoldingIDs.contains(holding.id) {
            writes.append(
                try RecordWrite(
                    holding,
                    id: holding.id.uuidString,
                    in: .investmentHoldings
                )
            )
        }
        if candidateProfile != profile, let candidateProfile {
            writes.append(
                try RecordWrite(
                    candidateProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                )
            )
        }
        if candidateDraft != quickLogDraft, let candidateDraft {
            writes.append(
                try RecordWrite(
                    candidateDraft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            )
        }
        writes.append(try lifecycleAuditWrite(audit))

        var deletions = [RecordDeletion(id: sourceID.uuidString, from: .accounts)]
        if source.kind == .expense,
           budgetNodes.contains(where: { $0.id == sourceID }) {
            deletions.append(
                RecordDeletion(id: sourceID.uuidString, from: .budgetNodes)
            )
        }

        let generation = storeGeneration
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await lifecycleStore.write(writes, removing: deletions)
        guard isCurrentStoreGeneration(generation) else { return }

        accounts = candidateAccounts
        if retainsCompleteJournal { entries = candidateEntries }
        budgetEntryAttributions = candidateBudgetAttributions
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
        scheduledTransactions = candidateSchedules.sorted {
            $0.nextOccurrence < $1.nextOccurrence
        }
        investmentHoldings = candidateHoldings
        profile = candidateProfile
        quickLogDraft = candidateDraft
        await refreshJournalAfterMutation()
    }
}
