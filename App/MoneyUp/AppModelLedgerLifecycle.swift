import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func addAccount(
        name: String,
        type: FinancialAccountType,
        currencyCode: String,
        startingBalance: Decimal = .zero
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        if (type.isLiabilityAccount || type == .restrictedAllowance),
           startingBalance < .zero {
            throw AppModelError.negativeAmount
        }
        let currency = try CurrencyCode(currencyCode)
        try requireValidNewWriteAmount(startingBalance, currency: currency)
        let account = LedgerAccount(
            name: normalizedName,
            kind: type.isLiabilityAccount ? .liability : .asset,
            currency: currency,
            accountType: type
        )
        var accountsToAdd = [account]
        var writes = [
            try RecordWrite(account, id: account.id.uuidString, in: .accounts)
        ]
        var openingEntry: JournalEntry?

        if startingBalance != .zero {
            let equity = openingBalancesAccount()
            if !accounts.contains(where: { $0.id == equity.id }) {
                accountsToAdd.append(equity)
                writes.append(
                    try RecordWrite(equity, id: equity.id.uuidString, in: .accounts)
                )
            }
            let candidate = try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(startingBalance, currency: currency),
                accountID: account.id,
                equityAccountID: equity.id,
                accountIsLiability: account.kind == .liability,
                note: AppLocalization.string("account.opening_balance_note")
            )
            let entry = try appAuthoredEntry(candidate)
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
            openingEntry = entry
        }

        let generation = storeGeneration
        let accountStore = try requireStore()
        if openingEntry != nil {
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
        }
        try await accountStore.write(writes)
        await lifecycleHooks.checkpoint(.afterAccountWriteBeforeApply)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: accountsToAdd)
        if retainsCompleteJournal, let openingEntry { entries.insert(openingEntry, at: 0) }
        if openingEntry != nil { await refreshJournalAfterMutation() }
    }

    @discardableResult
    func addCategory(
        name: String,
        kind: LedgerAccountKind,
        parentID: UUID? = nil
    ) async throws -> UUID {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard kind == .expense || kind == .income else {
            throw AppModelError.invalidCategoryKind
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        if let parentID {
            guard let parent = accountsByID[parentID],
                  parent.kind == kind,
                  !parent.isArchived,
                  parent.systemRole == nil else {
                throw AppModelError.invalidCategoryParent
            }
        }
        let category = LedgerAccount(
            name: normalizedName,
            kind: kind,
            parentID: parentID
        )
        let generation = storeGeneration
        let store = try requireStore()

        if kind == .expense, let currency = profile?.baseCurrency {
            let node = BudgetNode(
                id: category.id,
                parentID: parentID,
                name: normalizedName,
                limit: nil
            )
            let candidate = budgetNodes + [node]
            _ = try BudgetTree(currency: currency, nodes: candidate)
            let candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidate
            )
            try await store.write([
                try RecordWrite(category, id: category.id.uuidString, in: .accounts),
                try RecordWrite(node, id: node.id.uuidString, in: .budgetNodes),
                try budgetConfigurationTimelineWrite(candidateTimeline)
            ])
            guard isCurrentStoreGeneration(generation) else { return category.id }
            budgetConfigurationTimeline = candidateTimeline
            budgetNodes = candidate
        } else {
            try await store.upsert(category, id: category.id.uuidString, in: .accounts)
            guard isCurrentStoreGeneration(generation) else { return category.id }
        }
        accounts.append(category)
        return category.id
    }

    func lifecycleImpact(for id: UUID) -> LedgerItemLifecycleImpact {
        let transactionCount = retainsCompleteJournal
            ? entries.reduce(into: 0) { count, entry in
                if entry.postings.contains(where: { $0.accountID == id }) { count += 1 }
            }
            : journalReferenceCounts[id, default: 0]
        let scheduleCount = scheduledTransactions.reduce(into: 0) { count, schedule in
            if schedule.accountID == id || schedule.categoryAccountID == id { count += 1 }
        }
        let holdingCount = investmentHoldings.reduce(into: 0) { count, holding in
            if holding.accountID == id { count += 1 }
        }
        let childCount = accounts.reduce(into: 0) { count, account in
            if account.parentID == id { count += 1 }
        }
        let defaultReferenceCount: Int
        if let profile {
            defaultReferenceCount = [
                profile.preferredAccountID,
                profile.preferredExpenseCategoryID,
                profile.preferredIncomeCategoryID
            ].compactMap { $0 }.filter { $0 == id }.count
                + planningReferenceCount(to: id)
        } else {
            defaultReferenceCount = planningReferenceCount(to: id)
        }
        let draftReferenceCount: Int
        if let quickLogDraft {
            draftReferenceCount = [
                quickLogDraft.accountID,
                quickLogDraft.destinationAccountID,
                quickLogDraft.categoryID
            ].compactMap { $0 }.filter { $0 == id }.count
        } else {
            draftReferenceCount = 0
        }
        let budget = budgetNodes.first { $0.id == id }

        return LedgerItemLifecycleImpact(
            transactionCount: transactionCount,
            transactionReferencesAreCurrent: retainsCompleteJournal
                || journalReferenceCountsAreCurrent,
            scheduleCount: scheduleCount,
            holdingCount: holdingCount,
            childCount: childCount,
            defaultReferenceCount: defaultReferenceCount,
            draftReferenceCount: draftReferenceCount,
            hasConfiguredBudget: budget?.limit != nil
                || (budget?.purpose ?? .unclassified) != .unclassified
        )
    }

    func compatibleLifecycleTargets(for id: UUID) -> [LedgerAccount] {
        guard let source = accounts.first(where: { $0.id == id }),
              source.systemRole == nil,
              source.accountType != .restrictedAllowance else { return [] }
        let fundsInvestmentHolding = investmentHoldings.contains {
            $0.accountID == source.id
        }
        return accounts.filter {
            $0.id != source.id
                && $0.systemRole == nil
                && !$0.isArchived
                && $0.kind == source.kind
                && $0.currency == source.currency
                && $0.accountType != .restrictedAllowance
                && (!fundsInvestmentHolding
                    || isInvestmentFundingAccountShape($0))
        }
    }

    func compatibleCategoryParents(for id: UUID) -> [LedgerAccount] {
        guard let category = accountsByID[id],
              category.kind == .expense || category.kind == .income else { return [] }
        let descendants = descendantCategoryIDs(of: id)
        return accounts.filter {
            $0.id != id
                && !descendants.contains($0.id)
                && $0.kind == category.kind
                && !$0.isArchived
                && $0.systemRole == nil
        }.sorted { categoryPathName(for: $0.id) < categoryPathName(for: $1.id) }
    }

    func categoryPathName(for id: UUID) -> String {
        var names: [String] = []
        var currentID: UUID? = id
        var visited = Set<UUID>()
        while let candidate = currentID,
              let account = accountsByID[candidate],
              visited.insert(candidate).inserted {
            names.append(account.name)
            currentID = account.parentID
        }
        return names.reversed().joined(separator: " › ")
    }

    func reparentCategory(id: UUID, parentID: UUID?) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let original = accounts[index]
        try requireLifecycleEligible(original)
        guard original.kind == .expense || original.kind == .income else {
            throw AppModelError.invalidCategoryKind
        }
        if let parentID {
            guard compatibleCategoryParents(for: id).contains(where: {
                $0.id == parentID
            }) else { throw AppModelError.invalidCategoryParent }
        }
        guard original.parentID != parentID else { return }

        var updated = original
        updated.parentID = parentID
        var candidateBudgets = budgetNodes
        let beforeBudget = candidateBudgets.first { $0.id == id }
        if original.kind == .expense {
            guard let currency = profile?.baseCurrency,
                  let budgetIndex = candidateBudgets.firstIndex(where: {
                      $0.id == id
                  }) else { throw AppModelError.missingRecord }
            candidateBudgets[budgetIndex].parentID = parentID
            _ = try BudgetTree(currency: currency, nodes: candidateBudgets)
        } else {
            var cursor = parentID
            var visited = Set([id])
            while let candidate = cursor {
                guard visited.insert(candidate).inserted else {
                    throw AppModelError.invalidCategoryParent
                }
                cursor = accountsByID[candidate]?.parentID
            }
        }
        let afterBudget = candidateBudgets.first { $0.id == id }
        let timeline = original.kind == .expense
            ? try budgetConfigurationTimelineRecording(nodes: candidateBudgets)
            : nil
        let audit = LedgerAccountLifecycleAudit(
            action: .categoryMetadataUpdated,
            before: original,
            after: updated,
            beforeBudget: beforeBudget,
            afterBudget: afterBudget
        )
        var writes = [
            try RecordWrite(updated, id: updated.id.uuidString, in: .accounts),
            try lifecycleAuditWrite(audit)
        ]
        if let afterBudget {
            writes.append(
                try RecordWrite(afterBudget, id: afterBudget.id.uuidString, in: .budgetNodes)
            )
        }
        if let timeline { writes.append(try budgetConfigurationTimelineWrite(timeline)) }
        let generation = storeGeneration
        try await requireStore().write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts[index] = updated
        if let timeline { budgetConfigurationTimeline = timeline }
        budgetNodes = candidateBudgets
    }

    private func descendantCategoryIDs(of id: UUID) -> Set<UUID> {
        let children = Dictionary(grouping: accounts, by: \.parentID)
        var result = Set<UUID>()
        var stack = children[id, default: []].map(\.id)
        while let next = stack.popLast(), result.insert(next).inserted {
            stack.append(contentsOf: children[next, default: []].map(\.id))
        }
        return result
    }
}

extension AppModel {

    func renameLedgerItem(id: UUID, name: String) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let original = accounts[index]
        try requireLifecycleEligible(original)
        guard original.name != normalizedName else { return }

        var updated = original
        updated.name = normalizedName
        var candidateBudgets = budgetNodes
        var candidateTimeline: BudgetConfigurationTimeline?
        var writes = [
            try RecordWrite(updated, id: updated.id.uuidString, in: .accounts)
        ]
        if original.kind == .expense,
           let budgetIndex = candidateBudgets.firstIndex(where: { $0.id == id }) {
            candidateBudgets[budgetIndex].name = normalizedName
            writes.append(
                try RecordWrite(
                    candidateBudgets[budgetIndex],
                    id: id.uuidString,
                    in: .budgetNodes
                )
            )
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets
            )
            if let candidateTimeline {
                writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
            }
        }
        let audit = LedgerAccountLifecycleAudit(
            action: .renamed,
            before: original,
            after: updated,
            beforeBudget: budgetNodes.first { $0.id == id },
            afterBudget: candidateBudgets.first { $0.id == id }
        )
        writes.append(try lifecycleAuditWrite(audit))

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts[index] = updated
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
        if !retainsCompleteJournal { await refreshJournalAfterMutation() }
    }

    /// Saves an expense category's account name and planning metadata as one
    /// SQLCipher transaction. Validation is completed before any row is
    /// written, and the lifecycle audit is committed in the same batch.
    func updateCategoryMetadata(
        categoryID: UUID,
        name: String,
        amount: Decimal?,
        purpose: BudgetPurpose,
        pacingCadence: BudgetPacingCadence = .monthly,
        rolloverRule: BudgetRolloverRule
    ) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        guard let accountIndex = accounts.firstIndex(where: { $0.id == categoryID }) else {
            throw AppModelError.missingRecord
        }
        let originalAccount = accounts[accountIndex]
        try requireLifecycleEligible(originalAccount)
        guard originalAccount.kind == .expense || originalAccount.kind == .income else {
            throw AppModelError.invalidCategoryKind
        }

        var updatedAccount = originalAccount
        updatedAccount.name = normalizedName
        var candidateBudgets = budgetNodes
        let beforeBudget = budgetNodes.first { $0.id == categoryID }

        if originalAccount.kind == .expense {
            guard let currency = profile?.baseCurrency,
                  let budgetIndex = candidateBudgets.firstIndex(where: {
                      $0.id == categoryID
                  }) else {
                throw AppModelError.missingRecord
            }
            var updatedBudget = try budgetNodeUpdating(
                candidateBudgets[budgetIndex],
                amount: amount,
                purpose: purpose,
                pacingCadence: pacingCadence,
                rolloverRule: rolloverRule,
                currency: currency
            )
            updatedBudget.name = normalizedName
            candidateBudgets[budgetIndex] = updatedBudget
            _ = try BudgetTree(currency: currency, nodes: candidateBudgets)
        }

        let afterBudget = candidateBudgets.first { $0.id == categoryID }
        guard updatedAccount != originalAccount || afterBudget != beforeBudget else { return }
        let candidateTimeline: BudgetConfigurationTimeline?
        if originalAccount.kind == .expense {
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets
            )
        } else {
            candidateTimeline = nil
        }

        let audit = LedgerAccountLifecycleAudit(
            action: .categoryMetadataUpdated,
            before: originalAccount,
            after: updatedAccount,
            beforeBudget: beforeBudget,
            afterBudget: afterBudget
        )
        let writes = try categoryMetadataWrites(
            updatedAccount: updatedAccount,
            originalAccount: originalAccount,
            afterBudget: afterBudget,
            beforeBudget: beforeBudget,
            candidateTimeline: candidateTimeline,
            audit: audit
        )

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts[accountIndex] = updatedAccount
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
    }

    private func categoryMetadataWrites(
        updatedAccount: LedgerAccount,
        originalAccount: LedgerAccount,
        afterBudget: BudgetNode?,
        beforeBudget: BudgetNode?,
        candidateTimeline: BudgetConfigurationTimeline?,
        audit: LedgerAccountLifecycleAudit
    ) throws -> [RecordWrite] {
        var writes: [RecordWrite] = []
        if updatedAccount != originalAccount {
            writes.append(
                try RecordWrite(
                    updatedAccount,
                    id: updatedAccount.id.uuidString,
                    in: .accounts
                )
            )
        }
        if let afterBudget, afterBudget != beforeBudget {
            writes.append(
                try RecordWrite(
                    afterBudget,
                    id: afterBudget.id.uuidString,
                    in: .budgetNodes
                )
            )
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        writes.append(try lifecycleAuditWrite(audit))
        return writes
    }

    func setLedgerItemArchived(id: UUID, isArchived: Bool) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        await finishPendingQuickLogDraftWrite()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let original = accounts[index]
        try requireLifecycleEligible(original)
        guard original.isArchived != isArchived else { return }
        if isArchived {
            let hasScheduleReference = scheduledTransactions.contains {
                $0.accountID == id || $0.categoryAccountID == id
            }
            let fundsActiveHolding = investmentHoldings.contains {
                !$0.isArchived && $0.accountID == id
            }
            guard !hasScheduleReference, !fundsActiveHolding else {
                throw AppModelError.ledgerItemInUse
            }
            guard planningReferenceCount(to: id) == 0 else {
                throw AppModelError.ledgerItemInUse
            }
        }

        var updated = original
        updated.isArchived = isArchived
        var candidateProfile = profile
        var candidateDraft = quickLogDraft
        if isArchived {
            clearReferences(to: id, in: &candidateProfile)
            clearReferences(to: id, in: &candidateDraft)
        }

        var writes = [
            try RecordWrite(updated, id: updated.id.uuidString, in: .accounts)
        ]
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
        let audit = LedgerAccountLifecycleAudit(
            action: isArchived ? .archived : .restored,
            before: original,
            after: updated
        )
        writes.append(try lifecycleAuditWrite(audit))

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts[index] = updated
        profile = candidateProfile
        quickLogDraft = candidateDraft
    }

    func mergeLedgerItem(id sourceID: UUID, into targetID: UUID) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        try await reassignAndDeleteLedgerItem(
            id: sourceID,
            to: targetID,
            action: .merged
        )
    }

    func deleteLedgerItem(id: UUID, reassigningTo targetID: UUID? = nil) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        if let targetID {
            try await reassignAndDeleteLedgerItem(
                id: id,
                to: targetID,
                action: .deletedWithReassignment
            )
            return
        }

        await finishPendingQuickLogDraftWrite()
        guard let source = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        try requireLifecycleEligible(source)
        guard lifecycleImpact(for: id).isUnused else {
            throw AppModelError.ledgerItemInUse
        }

        let audit = LedgerAccountLifecycleAudit(
            action: .deleted,
            before: source,
            after: nil,
            beforeBudget: budgetNodes.first { $0.id == id }
        )
        let candidateBudgets = budgetNodes.filter { $0.id != id }
        let candidateTimeline: BudgetConfigurationTimeline?
        if source.kind == .expense {
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets
            )
        } else {
            candidateTimeline = nil
        }
        var writes = [try lifecycleAuditWrite(audit)]
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        var deletions = [RecordDeletion(id: id.uuidString, from: .accounts)]
        if source.kind == .expense,
           budgetNodes.contains(where: { $0.id == id }) {
            deletions.append(RecordDeletion(id: id.uuidString, from: .budgetNodes))
        }

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes, removing: deletions)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.removeAll { $0.id == id }
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
    }

    func setAccountBalance(accountID: UUID, displayBalance: Decimal) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let account = accounts.first(where: { $0.id == accountID }),
              !account.isArchived,
              let currency = account.currency else {
            throw AppModelError.missingRecord
        }
        guard account.systemRole != .investmentPosition else {
            throw AppModelError.investmentEntryMutationForbidden
        }
        if account.kind == .liability, displayBalance < .zero {
            throw AppModelError.negativeAmount
        }
        let adjustmentDate = currentDateForUserAction()
        let generation = storeGeneration
        let bookRevision = logicalBookRevision
        let projectionRevision = journalProjectionRevision
        let balanceStore = try requireStore()
        let current = try await currentBalanceForAdjustment(
            account: account,
            asOf: adjustmentDate,
            store: balanceStore,
            generation: generation,
            bookRevision: bookRevision,
            projectionRevision: projectionRevision
        )
        try requireValidNewWriteAmount(
            displayBalance,
            currency: currency,
            preserving: current
        )
        let delta = try CheckedDecimal.subtracting(displayBalance, current)
        guard delta != .zero else { return }
        if account.accountType == .restrictedAllowance {
            guard current >= .zero, delta >= .zero else {
                throw AppModelError.invalidAllowance
            }
        }
        try requireValidNewWriteAmount(delta, currency: currency)

        let equity = openingBalancesAccount()
        let shouldAddEquity = !accounts.contains(where: { $0.id == equity.id })
        let candidate = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(delta, currency: currency),
            accountID: account.id,
            equityAccountID: equity.id,
            accountIsLiability: account.kind == .liability,
            occurredAt: adjustmentDate,
            note: AppLocalization.string("account.balance_adjustment_note")
        )
        let entry = try appAuthoredEntry(candidate)
        var writes = [
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        if shouldAddEquity {
            writes.append(
                try RecordWrite(equity, id: equity.id.uuidString, in: .accounts)
            )
        }

        if account.accountType == .restrictedAllowance {
            try await requireNonnegativeRestrictedBalances(
                afterRemoving: nil,
                adding: entry,
                in: balanceStore
            )
        }
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await balanceStore.write(writes)
        guard isCurrentStoreGeneration(generation),
              logicalBookRevision == bookRevision,
              journalProjectionRevision == projectionRevision else { return }
        if shouldAddEquity { accounts.append(equity) }
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        await refreshJournalAfterMutation()
    }

    private func currentBalanceForAdjustment(
        account: LedgerAccount,
        asOf date: Date,
        store: EncryptedRecordStore,
        generation: Int,
        bookRevision: UInt64,
        projectionRevision: UInt64
    ) async throws -> Decimal {
        guard account.accountType == .restrictedAllowance else {
            switch displayBalanceResult(for: account) {
            case let .available(balance): return balance.amount
            case let .unavailable(issue): throw issue
            }
        }
        let balance = try await restrictedAllowanceBalance(
            for: account,
            asOf: date,
            in: store
        )
        guard ownsStoreGeneration(generation),
              logicalBookRevision == bookRevision,
              journalProjectionRevision == projectionRevision else {
            throw AppModelError.locked
        }
        return balance.amount
    }

    func planningReferenceCount(to id: UUID) -> Int {
        loanPlans.reduce(into: 0) { count, plan in
            if plan.accountID == id
                || plan.interestExpenseAccountID == id
                || plan.feeExpenseAccountID == id {
                count += 1
            }
        } + allowancePlans.reduce(into: 0) { count, plan in
            if plan.linkedAccountID == id
                || plan.eligibleCategoryIDs.contains(id)
                || plan.policyRevisions.contains(where: {
                    $0.eligibleCategoryIDs.contains(id)
                })
                || plan.usages.contains(where: { $0.categoryID == id }) {
                count += 1
            }
        }
    }
}
