import Foundation
import MoneyUpCore

extension AppModel {
    func beginAllowanceUsageMutation() throws {
        try beginJournalMutation(invalidatesJournalProjection: false)
        publishUnavailableBudgetWidgetSnapshot()
        widgetSnapshotRefreshWasDeferred = true
    }

    func updateUnlinkedBenefitAllowanceUsage(
        planID: UUID,
        expectedUsage: AllowanceUsage,
        expectedPolicyRevisionID: UUID,
        amount: Decimal,
        categoryID: UUID?,
        occurredAt: Date,
        note: String?
    ) async throws {
        try beginAllowanceUsageMutation()
        defer { endJournalMutation() }
        let (index, plan) = try currentUnlinkedBenefitUsage(
            planID: planID,
            expectedUsage: expectedUsage
        )
        guard let policy = plan.policy(at: occurredAt),
              policy.id == expectedPolicyRevisionID else {
            throw AppModelError.invalidAllowance
        }
        try requireAllowanceUsageCategory(categoryID, policy: policy)
        try requireValidNewWriteAmount(amount, currency: plan.amount.currency)
        let replacement = try AllowanceUsage(
            id: expectedUsage.id,
            amount: Money(amount, currency: plan.amount.currency),
            occurredAt: occurredAt,
            categoryID: categoryID,
            note: note,
            policyRevisionID: policy.id
        )
        let updated: AllowancePlan
        do {
            updated = try plan.replacingUsage(
                id: expectedUsage.id,
                with: replacement
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidAllowance
        }
        try await persistAllowanceUsageMutation(
            updated,
            replacing: plan,
            at: index
        )
    }

    func deleteUnlinkedBenefitAllowanceUsage(
        planID: UUID,
        expectedUsage: AllowanceUsage
    ) async throws -> AllowanceUsage {
        try beginAllowanceUsageMutation()
        defer { endJournalMutation() }
        let (index, plan) = try currentUnlinkedBenefitUsage(
            planID: planID,
            expectedUsage: expectedUsage
        )
        let updated: AllowancePlan
        do {
            updated = try plan.removingUsage(id: expectedUsage.id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidAllowance
        }
        try await persistAllowanceUsageMutation(
            updated,
            replacing: plan,
            at: index
        )
        return expectedUsage
    }

    func restoreDeletedUnlinkedBenefitAllowanceUsage(
        planID: UUID,
        deletedUsage: AllowanceUsage,
        expectedPolicyRevisionID: UUID
    ) async throws {
        try beginAllowanceUsageMutation()
        defer { endJournalMutation() }
        guard deletedUsage.linkedJournalEntryID == nil,
              deletedUsage.claimStatus == nil else {
            throw AppModelError.invalidAllowance
        }
        let planIndices = allowancePlans.indices.filter {
            allowancePlans[$0].id == planID
        }
        guard planIndices.count == 1,
              let index = planIndices.first else {
            throw AppModelError.invalidAllowance
        }
        let plan = allowancePlans[index]
        guard !plan.isArchived,
              !plan.hasGrandfatheredActivity,
              plan.fundingMode == .benefitLimit,
              isAllowanceWritable(plan),
              !plan.usages.contains(where: { $0.id == deletedUsage.id }),
              let policy = plan.policy(at: deletedUsage.occurredAt),
              policy.id == expectedPolicyRevisionID,
              deletedUsage.policyRevisionID == expectedPolicyRevisionID else {
            throw AppModelError.invalidAllowance
        }
        try requireAllowanceUsageCategory(
            deletedUsage.categoryID,
            policy: policy
        )
        let updated: AllowancePlan
        do {
            updated = try plan.addingUsage(deletedUsage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidAllowance
        }
        try await persistAllowanceUsageMutation(
            updated,
            replacing: plan,
            at: index
        )
    }

    private func currentUnlinkedBenefitUsage(
        planID: UUID,
        expectedUsage: AllowanceUsage
    ) throws -> (index: Int, plan: AllowancePlan) {
        let planIndices = allowancePlans.indices.filter {
            allowancePlans[$0].id == planID
        }
        guard planIndices.count == 1,
              let index = planIndices.first else {
            throw AppModelError.invalidAllowance
        }
        let plan = allowancePlans[index]
        let matches = plan.usages.filter { $0.id == expectedUsage.id }
        guard !plan.isArchived,
              !plan.hasGrandfatheredActivity,
              plan.fundingMode == .benefitLimit,
              isAllowanceWritable(plan),
              matches.count == 1,
              matches[0] == expectedUsage,
              expectedUsage.linkedJournalEntryID == nil,
              expectedUsage.claimStatus == nil else {
            throw AppModelError.invalidAllowance
        }
        return (index, plan)
    }

    private func requireAllowanceUsageCategory(
        _ categoryID: UUID?,
        policy: AllowancePolicyRevision
    ) throws {
        if let categoryID {
            guard let category = accountsByID[categoryID],
                  category.kind == .expense,
                  !category.isArchived,
                  policy.accepts(categoryID: categoryID) else {
                throw AppModelError.invalidAllowance
            }
        } else if !policy.eligibleCategoryIDs.isEmpty {
            throw AppModelError.invalidAllowance
        }
    }

    private func persistAllowanceUsageMutation(
        _ updated: AllowancePlan,
        replacing current: AllowancePlan,
        at index: Int
    ) async throws {
        let generation = storeGeneration
        try await requireStore().upsert(
            updated,
            id: updated.id.uuidString,
            in: .allowancePlans
        )
        await lifecycleHooks.checkpoint(.afterAllowanceUsageCommitBeforeApply)
        guard isCurrentStoreGeneration(generation),
              allowancePlans.indices.contains(index),
              allowancePlans[index] == current else {
            throw AppModelError.locked
        }
        allowancePlans[index] = updated
        refreshBudgetWidgetSnapshot()
    }
}
