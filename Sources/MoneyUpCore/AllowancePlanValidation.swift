import Foundation

extension AllowancePlan {
    static func validatedArchiveTransitions(
        _ supplied: [AllowanceArchiveTransition],
        startsAt: Date,
        currentState: Bool
    ) throws -> [AllowanceArchiveTransition] {
        guard supplied.count <= maximumArchiveTransitionCount else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        if supplied.isEmpty {
            return currentState
                ? [try AllowanceArchiveTransition(
                    effectiveAt: startsAt,
                    isArchived: true
                )]
                : []
        }

        var priorState = false
        var priorDate: Date?
        for transition in supplied {
            guard transition.effectiveAt.timeIntervalSinceReferenceDate.isFinite,
                  transition.effectiveAt >= startsAt,
                  priorDate.map({ $0 < transition.effectiveAt }) ?? true,
                  transition.isArchived != priorState else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            priorDate = transition.effectiveAt
            priorState = transition.isArchived
        }
        guard priorState == currentState else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        return supplied
    }

    static func isValidClaimTransition(
        from current: AllowanceClaimStatus?,
        to proposed: AllowanceClaimStatus
    ) -> Bool {
        guard let current else { return proposed == .pendingApproval }
        if current == proposed { return true }
        switch (current, proposed) {
        case (.pendingApproval, .approved),
             (.pendingApproval, .rejected),
             (.approved, .reimbursed):
            return true
        default:
            return false
        }
    }

    static func periodKey(
        policyID: UUID,
        interval: DateInterval
    ) -> String {
        [
            policyID.uuidString,
            String(interval.start.timeIntervalSinceReferenceDate),
            String(interval.end.timeIntervalSinceReferenceDate)
        ].joined(separator: "|")
    }

    static func validatedDefinitionName(
        _ name: String,
        amount: Money,
        startsAt: Date,
        endsAt: Date?,
        timeZoneIdentifier: String,
        eligibleCategoryIDs: Set<UUID>,
        rolloverRule: AllowanceRolloverRule,
        rolloverCap: Money?,
        usageCount: Int,
        policyRevisionCount: Int,
        reconciliationCount: Int
    ) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AllowancePlanError.emptyName }
        guard amount.amount > .zero else {
            throw AllowancePlanError.amountMustBePositive
        }
        guard startsAt.timeIntervalSinceReferenceDate.isFinite,
              endsAt?.timeIntervalSinceReferenceDate.isFinite != false,
              endsAt.map({ $0 > startsAt }) ?? true else {
            throw AllowancePlanError.invalidDate
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw AllowancePlanError.invalidTimeZone
        }
        guard eligibleCategoryIDs.count <= maximumEligibleCategoryCount else {
            throw AllowancePlanError.tooManyCategories
        }
        guard usageCount <= maximumUsageCount else {
            throw AllowancePlanError.tooManyUsages
        }
        guard policyRevisionCount <= maximumPolicyRevisionCount,
              reconciliationCount <= maximumReconciliationCount else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        if rolloverRule == .capped {
            guard let rolloverCap,
                  rolloverCap.currency == amount.currency,
                  rolloverCap.amount >= .zero else {
                throw AllowancePlanError.invalidRolloverCap
            }
        } else if rolloverCap != nil {
            throw AllowancePlanError.invalidRolloverCap
        }
        return normalized
    }

    static func validatedPolicyRevisions(
        _ supplied: [AllowancePolicyRevision],
        planID: UUID,
        amount: Money,
        cadence: AllowanceCadence,
        startsAt: Date,
        endsAt: Date?,
        timeZoneIdentifier: String,
        eligibleCategoryIDs: Set<UUID>,
        rolloverRule: AllowanceRolloverRule,
        rolloverCap: Money?
    ) throws -> [AllowancePolicyRevision] {
        let revisions = supplied.isEmpty
            ? [try AllowancePolicyRevision(
                id: planID,
                effectiveAt: startsAt,
                amount: amount,
                cadence: cadence,
                timeZoneIdentifier: timeZoneIdentifier,
                eligibleCategoryIDs: eligibleCategoryIDs,
                rolloverRule: rolloverRule,
                rolloverCap: rolloverCap
            )]
            : supplied.sorted { $0.effectiveAt < $1.effectiveAt }
        guard let latest = revisions.last,
              revisions.first?.effectiveAt == startsAt,
              Set(revisions.map(\.id)).count == revisions.count,
              zip(revisions, revisions.dropFirst()).allSatisfy({
                  $0.effectiveAt < $1.effectiveAt
              }),
              revisions.allSatisfy({ revision in
                  revision.amount.currency == amount.currency
                      && revision.effectiveAt >= startsAt
                      && (endsAt.map { revision.effectiveAt < $0 } ?? true)
              }),
              latest.amount == amount,
              latest.cadence == cadence,
              latest.timeZoneIdentifier == timeZoneIdentifier,
              latest.eligibleCategoryIDs == eligibleCategoryIDs,
              latest.rolloverRule == rolloverRule,
              latest.rolloverCap == rolloverCap else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        return revisions
    }

    static func validatedUsages(
        usages: [AllowanceUsage],
        revisions: [AllowancePolicyRevision],
        fundingMode: AllowanceFundingMode,
        grandfatheredActivity: Bool,
        currency: CurrencyCode,
        startsAt: Date,
        endsAt: Date?
    ) throws -> [AllowanceUsage] {
        let linkedUsageIDs = usages.compactMap(\.linkedJournalEntryID)
        guard grandfatheredActivity
                || Set(linkedUsageIDs).count == linkedUsageIDs.count else {
            throw AllowancePlanError.duplicateLinkedUsage
        }
        return try usages.map { usage in
            guard usage.amount.currency == currency else {
                throw AllowancePlanError.currencyMismatch
            }
            guard usage.occurredAt >= startsAt,
                  endsAt.map({ usage.occurredAt < $0 }) ?? true,
                  let policy = revisions.last(where: {
                      $0.effectiveAt <= usage.occurredAt
                  }),
                  usage.policyRevisionID.map({ $0 == policy.id }) ?? true else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            guard grandfatheredActivity
                    || policy.accepts(categoryID: usage.categoryID)
                    || (usage.categoryID == nil
                        && usage.linkedJournalEntryID != nil) else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            let status = try normalizedClaimStatus(
                usage.claimStatus,
                fundingMode: fundingMode
            )
            return try AllowanceUsage(
                id: usage.id,
                amount: usage.amount,
                occurredAt: usage.occurredAt,
                categoryID: usage.categoryID,
                linkedJournalEntryID: usage.linkedJournalEntryID,
                note: usage.note,
                policyRevisionID: policy.id,
                claimStatus: status
            )
        }
    }

    static func normalizedClaimStatus(
        _ status: AllowanceClaimStatus?,
        fundingMode: AllowanceFundingMode
    ) throws -> AllowanceClaimStatus? {
        switch fundingMode {
        case .benefitLimit, .prepaidAsset:
            guard status == nil else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            return nil
        case .reimbursement:
            return status ?? .pendingApproval
        }
    }

    static func validateReconciliations(
        _ reconciliations: [AllowanceReconciliation],
        revisions: [AllowancePolicyRevision],
        currency: CurrencyCode,
        startsAt: Date,
        endsAt: Date?
    ) throws {
        guard reconciliations.allSatisfy({ reconciliation in
            guard reconciliation.expired.currency == currency,
                  reconciliation.periodStart >= startsAt,
                  reconciliation.recordedAt >= reconciliation.periodEnd,
                  endsAt.map({ reconciliation.periodEnd <= $0 }) ?? true,
                  let index = revisions.firstIndex(where: {
                      $0.id == reconciliation.policyRevisionID
                  }) else { return false }
            let revision = revisions[index]
            let nextStart = revisions.indices.contains(index + 1)
                ? revisions[index + 1].effectiveAt : nil
            return reconciliation.periodStart >= revision.effectiveAt
                && (nextStart.map { reconciliation.periodEnd <= $0 } ?? true)
        }) else { throw AllowancePlanError.invalidPolicyRevision }
        let keys = reconciliations.map(reconciliationKey)
        guard Set(keys).count == keys.count else {
            throw AllowancePlanError.duplicateReconciliation
        }
    }

    static func reconciliationKey(_ item: AllowanceReconciliation) -> String {
        [
            item.policyRevisionID.uuidString,
            String(item.periodStart.timeIntervalSinceReferenceDate),
            String(item.periodEnd.timeIntervalSinceReferenceDate)
        ].joined(separator: "|")
    }
}
