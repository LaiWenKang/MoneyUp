import Foundation

public extension AllowancePlan {
    /// Removes one allowance-only benefit usage by stable evidence identity.
    /// Journal-linked usage must be changed through the journal workflow.
    func removingUsage(id usageID: UUID) throws -> AllowancePlan {
        let matches = usages.indices.filter { usages[$0].id == usageID }
        guard !isArchived,
              !hasGrandfatheredActivity,
              fundingMode == .benefitLimit,
              matches.count == 1,
              let index = matches.first,
              usages[index].linkedJournalEntryID == nil,
              usages[index].claimStatus == nil else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        var remaining = usages
        remaining.remove(at: index)
        return try AllowancePlan(
            id: id,
            name: name,
            amount: amount,
            cadence: cadence,
            fundingMode: fundingMode,
            linkedAccountID: linkedAccountID,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZoneIdentifier: timeZoneIdentifier,
            eligibleCategoryIDs: eligibleCategoryIDs,
            rolloverRule: rolloverRule,
            rolloverCap: rolloverCap,
            usages: remaining,
            policyRevisions: policyRevisions,
            reconciliations: reconciliations,
            hasGrandfatheredActivity: hasGrandfatheredActivity,
            isArchived: isArchived,
            archiveTransitions: archiveTransitions
        )
    }

    /// Replaces one allowance-only benefit usage without changing its UUID.
    /// Re-adding through the normal domain path rechecks date, revision,
    /// category, currency, and period capacity after the original is removed.
    func replacingUsage(
        id usageID: UUID,
        with replacement: AllowanceUsage
    ) throws -> AllowancePlan {
        guard replacement.id == usageID,
              replacement.linkedJournalEntryID == nil,
              replacement.claimStatus == nil else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        let candidate = try removingUsage(id: usageID).addingUsage(replacement)
        try candidate.validateAllowancePeriodBalances(validatesUsage: true)
        return candidate
    }
}
