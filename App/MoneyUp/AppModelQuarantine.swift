import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
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
        try quarantineInvalidAccountHierarchy(
            observesCancellation: observesCancellation
        )
        var accountIDs = Set(accounts.map(\.id))
        let retainedAccountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        quarantineInvalidBudgetRelationships()
        quarantineInvalidJournalRelationships(accountIDs: accountIDs)
        quarantineInvalidBudgetAttributions(
            existingEntryIDs: existingBudgetAttributionEntryIDs
        )
        try quarantineInvalidScheduleRelationships(
            accountIDs: accountIDs,
            existingEntryIDs: existingScheduledEntryIDs
        )
        try quarantineInvalidInvestmentRelationships(
            retainedAccountByID: retainedAccountByID,
            investmentEntriesByID: investmentEntriesByID
        )
        quarantineOrphanInvestmentPositions(accountIDs: &accountIDs)
        retainLinkedInvestmentEntries()
        quarantineInvalidReceiptRelationships(
            existingEntryIDs: existingAttachmentEntryIDs
        )
        quarantineDuplicateSavingsGoals()
    }

    func quarantineInvalidAccountHierarchy(
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
    }

    func quarantineInvalidBudgetRelationships() {
        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        let invalidBudgetIDs = Set(budgetNodes.filter {
            !expenseIDs.contains($0.id)
                || ($0.parentID.map { !expenseIDs.contains($0) } ?? false)
        }.map(\.id))
        if !invalidBudgetIDs.isEmpty {
            recoveryIssues.append(contentsOf: invalidBudgetIDs.map {
                "budgets/orphan-\($0)"
            })
            budgetNodes.removeAll { invalidBudgetIDs.contains($0.id) }
        }
        if let currency = profile?.baseCurrency,
           (try? BudgetTree(currency: currency, nodes: budgetNodes)) == nil,
           !budgetNodes.isEmpty {
            recoveryIssues.append("budgets/invalid-tree")
            budgetNodes = []
        }
    }

    func quarantineInvalidJournalRelationships(accountIDs: Set<UUID>) {
        entries.removeAll { entry in
            let invalid = entry.postings.contains {
                !accountIDs.contains($0.accountID)
            }
            if invalid {
                recoveryIssues.append("journal_entries/orphan-\(entry.id)")
            }
            return invalid
        }
    }

    func quarantineInvalidBudgetAttributions(
        existingEntryIDs: Set<UUID>?
    ) {
        let entryIDs = Set(entries.map(\.id))
        budgetEntryAttributions = budgetEntryAttributions.filter { item in
            let valid = existingEntryIDs?.contains(item.key)
                ?? entryIDs.contains(item.key)
            if !valid {
                recoveryIssues.append(
                    "budget_entry_attributions/orphan-\(item.key)"
                )
            }
            return valid
        }
    }

    func quarantineInvalidScheduleRelationships(
        accountIDs: Set<UUID>,
        existingEntryIDs: Set<UUID>?
    ) throws {
        var scheduleLinkOwners: [UUID: Set<UUID>] = [:]
        for schedule in scheduledTransactions {
            for entryID in schedule.resolutions.compactMap(\.linkedEntryID) {
                scheduleLinkOwners[entryID, default: []].insert(schedule.id)
            }
        }
        let reusedScheduleEntryIDs = Set(
            scheduleLinkOwners.filter { $0.value.count > 1 }.keys
        )
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
                || existingEntryIDs.map {
                    !linkedEntryIDs.isSubset(of: $0)
                } == true
            if invalid {
                recoveryIssues.append("scheduled_transactions/orphan-\(item.id)")
            }
            return invalid
        }
    }

    func quarantineInvalidInvestmentRelationships(
        retainedAccountByID: [UUID: LedgerAccount],
        investmentEntriesByID: [UUID: JournalEntry]
    ) throws {
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
            let invalid = try isInvalidRecoveryInvestmentHolding(
                holding,
                duplicateHoldingIDs: duplicateHoldingIDs,
                duplicatePositionIDs: duplicatePositionIDs,
                reusedEntryIDs: reusedEntryIDs,
                retainedAccountByID: retainedAccountByID,
                investmentEntriesByID: investmentEntriesByID
            )
            if invalid {
                recoveryIssues.append("investment_holdings/orphan-\(holding.id)")
            }
            return invalid
        }
    }

    func isInvalidRecoveryInvestmentHolding(
        _ holding: InvestmentHolding,
        duplicateHoldingIDs: Set<UUID>,
        duplicatePositionIDs: Set<UUID>,
        reusedEntryIDs: Set<UUID>,
        retainedAccountByID: [UUID: LedgerAccount],
        investmentEntriesByID: [UUID: JournalEntry]
    ) throws -> Bool {
        let funding = retainedAccountByID[holding.accountID]
        let position = holding.positionAccountID.flatMap {
            retainedAccountByID[$0]
        }
        let invalidFunding = funding.map {
            !isInvestmentFundingAccountShape($0)
                || (!holding.isArchived && $0.isArchived)
        } ?? true
        let invalidPosition = invalidRecoveryInvestmentPosition(
            holding,
            position: position,
            funding: funding
        )
        let invalidLinks = try hasInvalidRecoveryInvestmentLinks(
            holding,
            accountsByID: retainedAccountByID,
            entriesByID: investmentEntriesByID
        )
        return duplicateHoldingIDs.contains(holding.id)
            || holding.positionAccountID.map(duplicatePositionIDs.contains) == true
            || !holding.linkedEntryIDs.isDisjoint(with: reusedEntryIDs)
            || invalidFunding
            || recoveryHoldingCurrencies(holding).contains {
                $0 != funding?.currency
            }
            || invalidPosition
            || invalidLinks
    }

    func recoveryHoldingCurrencies(
        _ holding: InvestmentHolding
    ) -> Set<CurrencyCode> {
        Set(
            Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
        )
    }

    func invalidRecoveryInvestmentPosition(
        _ holding: InvestmentHolding,
        position: LedgerAccount?,
        funding: LedgerAccount?
    ) -> Bool {
        if let positionID = holding.positionAccountID {
            return positionID == holding.accountID
                || position?.systemRole != .investmentPosition
                || position?.kind != .asset
                || position?.currency != funding?.currency
                || position?.isArchived != holding.isArchived
        }
        return holding.isArchived
            || !holding.linkedEntryIDs.isEmpty
            || !(holding.quantity == .zero || holding.needsLedgerConnection)
    }

    func hasInvalidRecoveryInvestmentLinks(
        _ holding: InvestmentHolding,
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry]
    ) throws -> Bool {
        guard holding.positionAccountID != nil else {
            return !holding.linkedEntryIDs.isEmpty
        }
        do {
            try InvestmentLedgerIntegrity.validate(
                holding: holding,
                accountsByID: accountsByID,
                entriesByID: entriesByID
            )
            return false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return true
        }
    }

    func quarantineOrphanInvestmentPositions(
        accountIDs: inout Set<UUID>
    ) {
        let retainedPositionIDs = Set(
            investmentHoldings.compactMap(\.positionAccountID)
        )
        let activeOrphanPositionIDs = Set(accounts.compactMap { account -> UUID? in
            guard account.systemRole == .investmentPosition,
                  !account.isArchived,
                  !retainedPositionIDs.contains(account.id) else { return nil }
            return account.id
        })
        guard !activeOrphanPositionIDs.isEmpty else { return }
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

    func retainLinkedInvestmentEntries() {
        let retainedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        investmentLinkedEntriesByID = investmentLinkedEntriesByID.filter {
            retainedInvestmentEntryIDs.contains($0.key)
        }
    }

    func quarantineInvalidReceiptRelationships(
        existingEntryIDs: Set<UUID>?
    ) {
        let attachmentEntryIDs = existingEntryIDs ?? Set(entries.map(\.id))
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
    }

    func quarantineDuplicateSavingsGoals() {
        var seenGoalIDs = Set<UUID>()
        savingsGoals = savingsGoals.filter { goal in
            let unique = seenGoalIDs.insert(goal.id).inserted
            if !unique {
                recoveryIssues.append("savings_goals/duplicate-\(goal.id)")
            }
            return unique
        }
    }
}

extension AppModel {
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
