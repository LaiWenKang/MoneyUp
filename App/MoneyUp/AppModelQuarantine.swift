import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

struct AppModelLedgerReassignmentHierarchy: Sendable {
    let accounts: [LedgerAccount]
    let budgets: [BudgetNode]
    let timeline: BudgetConfigurationTimeline?
}

struct AppModelLedgerReassignmentJournal: Sendable {
    let entries: [JournalEntry]
    let originalsByID: [UUID: JournalEntry]
}

struct AppModelLedgerReassignmentAttributions: Sendable {
    let values: [UUID: BudgetEntryAttribution]
    let additions: [BudgetEntryAttribution]
}

struct AppModelLedgerReassignmentSchedules: Sendable {
    let values: [ScheduledTransaction]
    let changedIDs: Set<UUID>
}

struct AppModelLedgerReassignmentHoldings: Sendable {
    let values: [InvestmentHolding]
    let changedIDs: Set<UUID>
}

struct AppModelLedgerReassignmentPlan: Sendable {
    let store: EncryptedRecordStore
    let source: LedgerAccount
    let hierarchy: AppModelLedgerReassignmentHierarchy
    let journal: AppModelLedgerReassignmentJournal
    let attributions: AppModelLedgerReassignmentAttributions
    let schedules: AppModelLedgerReassignmentSchedules
    let holdings: AppModelLedgerReassignmentHoldings
    let profile: UserProfile?
    let draft: QuickLogDraft?
    let audit: LedgerAccountLifecycleAudit
}

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
        existingPlanningEntryIDs: Set<UUID> = [],
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
        quarantineInvalidLoanRelationships(
            retainedAccountByID: retainedAccountByID,
            existingEntryIDs: existingPlanningEntryIDs
        )
        try quarantineInvalidAllowanceRelationships(
            retainedAccountByID: retainedAccountByID,
            existingEntryIDs: existingPlanningEntryIDs,
            observesCancellation: observesCancellation
        )
    }

    func quarantineInvalidLoanRelationships(
        retainedAccountByID: [UUID: LedgerAccount],
        existingEntryIDs: Set<UUID>
    ) {
        let duplicateAccountIDs = Set(
            Dictionary(grouping: loanPlans, by: \.accountID)
                .filter { $0.value.count > 1 }.keys
        )
        var activityOwners: [UUID: Set<UUID>] = [:]
        for plan in loanPlans {
            for activity in plan.activities {
                activityOwners[activity.journalEntryID, default: []].insert(plan.id)
            }
        }
        let reusedEntries = Set(activityOwners.filter { $0.value.count > 1 }.keys)
        loanPlans.removeAll { plan in
            let account = retainedAccountByID[plan.accountID]
            let activityIDs = Set(plan.activities.map(\.journalEntryID))
            let invalid = account?.kind != .liability
                || account?.accountType != .loan
                || account?.currency != plan.originalPrincipal.currency
                || duplicateAccountIDs.contains(plan.accountID)
                || !activityIDs.isDisjoint(with: reusedEntries)
                || !activityIDs.isSubset(of: existingEntryIDs)
                || plan.interestExpenseAccountID.map {
                    retainedAccountByID[$0]?.kind != .expense
                } == true
                || plan.feeExpenseAccountID.map {
                    retainedAccountByID[$0]?.kind != .expense
                } == true
            if invalid { recoveryIssues.append("loan_plans/orphan-\(plan.id)") }
            return invalid
        }
    }

    func quarantineInvalidAllowanceRelationships(
        retainedAccountByID: [UUID: LedgerAccount],
        existingEntryIDs: Set<UUID>,
        observesCancellation: Bool
    ) throws {
        var prepaidAccountCounts: [UUID: Int] = [:]
        for (offset, plan) in allowancePlans.enumerated() {
            if observesCancellation, offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard !plan.isArchived,
                  plan.fundingMode == .prepaidAsset,
                  let accountID = plan.linkedAccountID,
                  Self.allowanceFundingCompatibility(
                      for: plan,
                      accountsByID: retainedAccountByID
                  ) == .current else { continue }
            prepaidAccountCounts[accountID, default: 0] += 1
        }
        var duplicatePrepaidAccountIDs = Set<UUID>()
        for item in prepaidAccountCounts where item.value > 1 {
            duplicatePrepaidAccountIDs.insert(item.key)
        }
        var retained: [AllowancePlan] = []
        var relationshipCount = 0
        for (offset, plan) in allowancePlans.enumerated() {
            if observesCancellation, offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let invalid = try allowanceRelationshipIsInvalid(
                plan,
                retainedAccountByID: retainedAccountByID,
                existingEntryIDs: existingEntryIDs,
                duplicatePrepaidAccountIDs: duplicatePrepaidAccountIDs,
                relationshipCount: &relationshipCount,
                observesCancellation: observesCancellation
            )
            if invalid {
                recoveryIssues.append("allowance_plans/orphan-\(plan.id)")
            } else {
                retained.append(plan)
            }
        }
        allowancePlans = retained
    }

    private func allowanceRelationshipIsInvalid(
        _ plan: AllowancePlan,
        retainedAccountByID: [UUID: LedgerAccount],
        existingEntryIDs: Set<UUID>,
        duplicatePrepaidAccountIDs: Set<UUID>,
        relationshipCount: inout Int,
        observesCancellation: Bool
    ) throws -> Bool {
        var hasInvalidCategory = false
        var hasInvalidEntryLink = false
        for categoryID in plan.eligibleCategoryIDs {
            try checkAllowanceRelationshipCancellation(
                &relationshipCount,
                observesCancellation: observesCancellation
            )
            if retainedAccountByID[categoryID]?.kind != .expense {
                hasInvalidCategory = true
            }
        }
        for policy in plan.policyRevisions {
            for categoryID in policy.eligibleCategoryIDs {
                try checkAllowanceRelationshipCancellation(
                    &relationshipCount,
                    observesCancellation: observesCancellation
                )
                if retainedAccountByID[categoryID]?.kind != .expense {
                    hasInvalidCategory = true
                }
            }
        }
        for usage in plan.usages {
            try checkAllowanceRelationshipCancellation(
                &relationshipCount,
                observesCancellation: observesCancellation
            )
            if let categoryID = usage.categoryID,
               retainedAccountByID[categoryID]?.kind != .expense {
                hasInvalidCategory = true
            }
            if let entryID = usage.linkedJournalEntryID,
               !existingEntryIDs.contains(entryID) {
                hasInvalidEntryLink = true
            }
        }
        for reconciliation in plan.reconciliations {
            try checkAllowanceRelationshipCancellation(
                &relationshipCount,
                observesCancellation: observesCancellation
            )
            if let entryID = reconciliation.linkedJournalEntryID,
               !existingEntryIDs.contains(entryID) {
                hasInvalidEntryLink = true
            }
        }
        let compatibility = Self.allowanceFundingCompatibility(
            for: plan,
            accountsByID: retainedAccountByID
        )
        return hasInvalidCategory || hasInvalidEntryLink
            || compatibility == .invalid
            || (!plan.isArchived
                && plan.fundingMode == .prepaidAsset
                && plan.linkedAccountID.map(
                    duplicatePrepaidAccountIDs.contains
                ) == true
                && compatibility == .current)
    }

    private func checkAllowanceRelationshipCancellation(
        _ count: inout Int,
        observesCancellation: Bool
    ) throws {
        if observesCancellation, count.isMultiple(of: 256) {
            try Task.checkCancellation()
        }
        count += 1
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
        return quarantineInvestmentLedgerMismatches(balances: balances)
    }

    /// Recovery uses the unpublished compact snapshot so an account removal
    /// cannot race ahead of the balance universe used for this decision.
    @discardableResult
    func quarantineInvestmentLedgerMismatches(
        balances: [UUID: [CurrencyCode: Money]]
    ) -> Bool {
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
        let (source, target) = try validatedLedgerReassignmentEndpoints(
            sourceID: sourceID,
            targetID: targetID
        )
        let plan = try await prepareLedgerItemReassignment(
            source: source,
            target: target,
            action: action
        )
        let writes = try ledgerReassignmentWrites(for: plan)
        let deletions = ledgerReassignmentDeletions(for: plan)
        let generation = storeGeneration
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await plan.store.write(writes, removing: deletions)
        guard isCurrentStoreGeneration(generation) else { return }
        applyLedgerReassignmentPlan(plan)
        await refreshJournalAfterMutation()
    }
}

extension AppModel {
    func validatedLedgerReassignmentEndpoints(
        sourceID: UUID,
        targetID: UUID
    ) throws -> (source: LedgerAccount, target: LedgerAccount) {
        guard let source = accounts.first(where: { $0.id == sourceID }),
              let target = accounts.first(where: { $0.id == targetID }) else {
            throw AppModelError.missingRecord
        }
        try requireLifecycleEligible(source)
        try requireLifecycleEligible(target)
        try requireNonrestrictedLifecycleReassignment(
            source: source,
            target: target
        )
        guard planningReferenceCount(to: sourceID) == 0 else {
            throw AppModelError.ledgerItemInUse
        }
        guard sourceID != targetID else {
            throw AppModelError.incompatibleLedgerItems
        }
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
        return (source, target)
    }

    func prepareLedgerItemReassignment(
        source: LedgerAccount,
        target: LedgerAccount,
        action: LedgerAccountLifecycleAction
    ) async throws -> AppModelLedgerReassignmentPlan {
        let hierarchy = try ledgerReassignmentHierarchy(
            source: source,
            target: target
        )
        let journal = try await ledgerReassignmentJournal(
            sourceID: source.id,
            targetID: target.id
        )
        let lifecycleStore = try requireStore()
        if source.kind == .expense {
            try await loadCompleteBudgetAttributionCacheIfNeeded(
                from: lifecycleStore
            )
        }
        let attributions = try ledgerReassignmentAttributions(
            source: source,
            originalsByID: journal.originalsByID
        )
        let schedules = ledgerReassignmentSchedules(
            sourceID: source.id,
            targetID: target.id
        )
        let holdings = ledgerReassignmentHoldings(
            sourceID: source.id,
            targetID: target.id
        )
        try validateLifecycleRelationshipCandidates(
            source: source,
            target: target,
            accounts: hierarchy.accounts,
            entries: journal.entries,
            schedules: schedules.values,
            holdings: holdings.values
        )
        var candidateProfile = profile
        var candidateDraft = quickLogDraft
        repointReferences(
            from: source.id,
            to: target.id,
            in: &candidateProfile
        )
        repointReferences(
            from: source.id,
            to: target.id,
            in: &candidateDraft
        )
        let audit = try ledgerReassignmentAudit(
            action: action,
            source: source,
            targetID: target.id,
            hierarchy: hierarchy,
            journal: journal,
            schedules: schedules,
            holdings: holdings
        )
        return AppModelLedgerReassignmentPlan(
            store: lifecycleStore,
            source: source,
            hierarchy: hierarchy,
            journal: journal,
            attributions: attributions,
            schedules: schedules,
            holdings: holdings,
            profile: candidateProfile,
            draft: candidateDraft,
            audit: audit
        )
    }

    func ledgerReassignmentHierarchy(
        source: LedgerAccount,
        target: LedgerAccount
    ) throws -> AppModelLedgerReassignmentHierarchy {
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
                    sourceID: source.id,
                    targetID: target.id
                )]
            )
        } else {
            candidateTimeline = nil
        }
        return AppModelLedgerReassignmentHierarchy(
            accounts: candidateAccounts,
            budgets: candidateBudgets,
            timeline: candidateTimeline
        )
    }

    func ledgerReassignmentJournal(
        sourceID: UUID,
        targetID: UUID
    ) async throws -> AppModelLedgerReassignmentJournal {
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
        var originalsByID: [UUID: JournalEntry] = [:]
        let candidates = try sourceEntries.map { entry in
            guard entry.postings.contains(where: {
                $0.accountID == sourceID
            }) else { return entry }
            originalsByID[entry.id] = entry
            return try repoint(entry: entry, from: sourceID, to: targetID)
        }
        return AppModelLedgerReassignmentJournal(
            entries: candidates,
            originalsByID: originalsByID
        )
    }
}

extension AppModel {
    func ledgerReassignmentAttributions(
        source: LedgerAccount,
        originalsByID: [UUID: JournalEntry]
    ) throws -> AppModelLedgerReassignmentAttributions {
        var candidates = budgetEntryAttributions
        var additions: [BudgetEntryAttribution] = []
        if source.kind == .expense {
            for original in originalsByID.values
            where candidates[original.id] == nil {
                let attribution = try BudgetEntryAttribution(
                    entry: original,
                    originTimeZoneIdentifier:
                        profile?.reportingTimeZoneIdentifier
                        ?? reportingCalendar.timeZone.identifier
                )
                candidates[original.id] = attribution
                additions.append(attribution)
            }
        }
        return AppModelLedgerReassignmentAttributions(
            values: candidates,
            additions: additions
        )
    }

    func ledgerReassignmentSchedules(
        sourceID: UUID,
        targetID: UUID
    ) -> AppModelLedgerReassignmentSchedules {
        var changedIDs = Set<UUID>()
        let candidates = scheduledTransactions.map { schedule in
            var updated = schedule
            if updated.accountID == sourceID {
                updated.accountID = targetID
                changedIDs.insert(updated.id)
            }
            if updated.categoryAccountID == sourceID {
                updated.categoryAccountID = targetID
                changedIDs.insert(updated.id)
            }
            return updated
        }
        return AppModelLedgerReassignmentSchedules(
            values: candidates,
            changedIDs: changedIDs
        )
    }

    func ledgerReassignmentHoldings(
        sourceID: UUID,
        targetID: UUID
    ) -> AppModelLedgerReassignmentHoldings {
        var changedIDs = Set<UUID>()
        let candidates = investmentHoldings.map { holding in
            var updated = holding
            if updated.accountID == sourceID {
                updated.accountID = targetID
                changedIDs.insert(updated.id)
            }
            return updated
        }
        return AppModelLedgerReassignmentHoldings(
            values: candidates,
            changedIDs: changedIDs
        )
    }

    func ledgerReassignmentAudit(
        action: LedgerAccountLifecycleAction,
        source: LedgerAccount,
        targetID: UUID,
        hierarchy: AppModelLedgerReassignmentHierarchy,
        journal: AppModelLedgerReassignmentJournal,
        schedules: AppModelLedgerReassignmentSchedules,
        holdings: AppModelLedgerReassignmentHoldings
    ) throws -> LedgerAccountLifecycleAudit {
        guard let resultingTarget = hierarchy.accounts.first(where: {
            $0.id == targetID
        }) else { throw AppModelError.invalidBook }
        return LedgerAccountLifecycleAudit(
            action: action,
            before: source,
            after: resultingTarget,
            targetID: targetID,
            beforeBudget: budgetNodes.first { $0.id == source.id },
            afterBudget: hierarchy.budgets.first { $0.id == targetID },
            affectedJournalEntryIDs: Array(journal.originalsByID.keys),
            affectedScheduleIDs: Array(schedules.changedIDs),
            affectedHoldingIDs: Array(holdings.changedIDs)
        )
    }
}

extension AppModel {
    func ledgerReassignmentWrites(
        for plan: AppModelLedgerReassignmentPlan
    ) throws -> [RecordWrite] {
        var writes = try ledgerReassignmentAccountAndJournalWrites(for: plan)
        writes += try ledgerReassignmentRelationshipWrites(for: plan)
        writes += try ledgerReassignmentReferenceWrites(for: plan)
        return writes
    }

    func ledgerReassignmentAccountAndJournalWrites(
        for plan: AppModelLedgerReassignmentPlan
    ) throws -> [RecordWrite] {
        var writes: [RecordWrite] = []
        let originalAccountsByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        for account in plan.hierarchy.accounts
        where originalAccountsByID[account.id] != account {
            writes.append(
                try RecordWrite(
                    account,
                    id: account.id.uuidString,
                    in: .accounts
                )
            )
        }
        for entry in plan.journal.entries
        where plan.journal.originalsByID[entry.id] != nil {
            guard let original = plan.journal.originalsByID[entry.id] else {
                continue
            }
            writes.append(
                try RecordWrite(
                    original,
                    id: "\(original.id.uuidString)-lifecycle-\(plan.audit.id.uuidString)",
                    in: .journalEntryRevisions
                )
            )
            writes.append(
                try RecordWrite(
                    entry,
                    id: entry.id.uuidString,
                    in: .journalEntries
                )
            )
        }
        writes += try plan.attributions.additions.map {
            try RecordWrite(
                $0,
                id: $0.id.uuidString,
                in: .budgetEntryAttributions
            )
        }
        return writes
    }

    func ledgerReassignmentRelationshipWrites(
        for plan: AppModelLedgerReassignmentPlan
    ) throws -> [RecordWrite] {
        var writes: [RecordWrite] = []
        let originalBudgetsByID = Dictionary(
            uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) }
        )
        for node in plan.hierarchy.budgets
        where originalBudgetsByID[node.id] != node {
            writes.append(
                try RecordWrite(node, id: node.id.uuidString, in: .budgetNodes)
            )
        }
        if let timeline = plan.hierarchy.timeline {
            writes.append(try budgetConfigurationTimelineWrite(timeline))
        }
        for schedule in plan.schedules.values
        where plan.schedules.changedIDs.contains(schedule.id) {
            writes.append(
                try RecordWrite(
                    schedule,
                    id: schedule.id.uuidString,
                    in: .scheduledTransactions
                )
            )
        }
        for holding in plan.holdings.values
        where plan.holdings.changedIDs.contains(holding.id) {
            writes.append(
                try RecordWrite(
                    holding,
                    id: holding.id.uuidString,
                    in: .investmentHoldings
                )
            )
        }
        return writes
    }

    func ledgerReassignmentReferenceWrites(
        for plan: AppModelLedgerReassignmentPlan
    ) throws -> [RecordWrite] {
        var writes: [RecordWrite] = []
        if plan.profile != profile, let candidateProfile = plan.profile {
            writes.append(
                try RecordWrite(
                    candidateProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                )
            )
        }
        if plan.draft != quickLogDraft, let candidateDraft = plan.draft {
            writes.append(
                try RecordWrite(
                    candidateDraft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            )
        }
        writes.append(try lifecycleAuditWrite(plan.audit))
        return writes
    }

    func ledgerReassignmentDeletions(
        for plan: AppModelLedgerReassignmentPlan
    ) -> [RecordDeletion] {
        var deletions = [RecordDeletion(
            id: plan.source.id.uuidString,
            from: .accounts
        )]
        if plan.source.kind == .expense,
           budgetNodes.contains(where: { $0.id == plan.source.id }) {
            deletions.append(
                RecordDeletion(
                    id: plan.source.id.uuidString,
                    from: .budgetNodes
                )
            )
        }
        return deletions
    }

    func applyLedgerReassignmentPlan(
        _ plan: AppModelLedgerReassignmentPlan
    ) {
        accounts = plan.hierarchy.accounts
        if retainsCompleteJournal { entries = plan.journal.entries }
        budgetEntryAttributions = plan.attributions.values
        if let timeline = plan.hierarchy.timeline {
            budgetConfigurationTimeline = timeline
        }
        budgetNodes = plan.hierarchy.budgets
        scheduledTransactions = plan.schedules.values.sorted {
            $0.nextOccurrence < $1.nextOccurrence
        }
        investmentHoldings = plan.holdings.values
        profile = plan.profile
        quickLogDraft = plan.draft
    }
}
