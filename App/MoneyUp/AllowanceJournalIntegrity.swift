import Foundation
import MoneyUpCore

struct AllowanceJournalIntegrityResult: Equatable {
    let invalidPlanIDs: Set<UUID>
    let unauthorizedRestrictedDebitEntryIDs: Set<UUID>
    let invalidPrepaidEvidenceEntryIDs: Set<UUID>
}

/// Cross-record evidence rules that `AllowancePlan` cannot enforce while it is
/// decoded in isolation. Restricted debits are authorized bidirectionally:
/// every live debit needs exactly one valid plan claim, and every claim must be
/// supported by the immutable facts of its linked journal entry.
enum AllowanceJournalIntegrity {
    // `sourceSystem` is portable descriptive metadata, not an authorization
    // namespace. This label becomes authoritative only when a reconciliation
    // also matches its plan/revision fingerprint, origin context, exact date,
    // and postings. A label alone must not require a full-journal startup scan.
    static let expirySourceSystem = "moneyup.allowance.expiry"

    static func validationResult(
        plans: [AllowancePlan],
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry],
        liveRestrictedDebitEntryIDs suppliedDebitIDs: Set<UUID>? = nil,
        restrictedLedgerEvents suppliedRestrictedEvents: [LedgerPostingEvent]? = nil,
        preinvalidPlanIDs: Set<UUID> = [],
        observesCancellation: Bool = true
    ) throws -> AllowanceJournalIntegrityResult {
        var evidenceByEntryID: [UUID: [EvidenceAssessment]] = [:]
        var invalidPlanIDs = preinvalidPlanIDs
        let openingBalancesAccountID = try canonicalOpeningBalancesAccountID(
            accountsByID,
            observesCancellation: observesCancellation
        )
        for (offset, plan) in plans.enumerated() {
            if observesCancellation, offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            try assessUsages(
                plan,
                accountsByID: accountsByID,
                entriesByID: entriesByID,
                evidenceByEntryID: &evidenceByEntryID,
                invalidPlanIDs: &invalidPlanIDs,
                observesCancellation: observesCancellation
            )
            try assessReconciliations(
                plan,
                accountsByID: accountsByID,
                entriesByID: entriesByID,
                evidenceByEntryID: &evidenceByEntryID,
                invalidPlanIDs: &invalidPlanIDs,
                openingBalancesAccountID: openingBalancesAccountID,
                observesCancellation: observesCancellation
            )
        }
        for (offset, evidence) in evidenceByEntryID.values.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard evidence.count > 1 else { continue }
            invalidPlanIDs.formUnion(evidence.map(\.planID))
        }

        return try finalizedResult(
            plans: plans,
            accountsByID: accountsByID,
            entriesByID: entriesByID,
            evidenceByEntryID: evidenceByEntryID,
            invalidPlanIDs: invalidPlanIDs,
            suppliedDebitIDs: suppliedDebitIDs,
            suppliedRestrictedEvents: suppliedRestrictedEvents,
            observesCancellation: observesCancellation
        )
    }

    private static func finalizedResult(
        plans: [AllowancePlan],
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry],
        evidenceByEntryID: [UUID: [EvidenceAssessment]],
        invalidPlanIDs initialInvalidPlanIDs: Set<UUID>,
        suppliedDebitIDs: Set<UUID>?,
        suppliedRestrictedEvents: [LedgerPostingEvent]?,
        observesCancellation: Bool
    ) throws -> AllowanceJournalIntegrityResult {
        var invalidPlanIDs = initialInvalidPlanIDs
        let liveDebitIDs = try suppliedDebitIDs ?? restrictedDebitEntryIDs(
            in: entriesByID.values,
            accountsByID: accountsByID,
            observesCancellation: observesCancellation
        )
        var authorizedDebitIDs = try authorizedRestrictedDebitEntryIDs(
            evidenceByEntryID,
            invalidPlanIDs: invalidPlanIDs,
            observesCancellation: observesCancellation
        )
        var invalidPrepaidEvidenceIDs = try invalidPrepaidEvidenceEntryIDs(
            plans: plans,
            invalidPlanIDs: invalidPlanIDs,
            accountsByID: accountsByID,
            observesCancellation: observesCancellation
        )
        let excludedEntryIDs = liveDebitIDs.subtracting(authorizedDebitIDs)
            .union(invalidPrepaidEvidenceIDs)
        invalidPlanIDs.formUnion(try AllowanceExpiryFundingIntegrity.invalidPlanIDs(
            plans: plans,
            invalidPlanIDs: invalidPlanIDs,
            accountsByID: accountsByID,
            entriesByID: entriesByID,
            suppliedRestrictedEvents: suppliedRestrictedEvents,
            excludingEntryIDs: excludedEntryIDs,
            observesCancellation: observesCancellation
        ))
        authorizedDebitIDs = try authorizedRestrictedDebitEntryIDs(
            evidenceByEntryID,
            invalidPlanIDs: invalidPlanIDs,
            observesCancellation: observesCancellation
        )
        invalidPrepaidEvidenceIDs = try invalidPrepaidEvidenceEntryIDs(
            plans: plans,
            invalidPlanIDs: invalidPlanIDs,
            accountsByID: accountsByID,
            observesCancellation: observesCancellation
        )
        return AllowanceJournalIntegrityResult(
            invalidPlanIDs: invalidPlanIDs,
            unauthorizedRestrictedDebitEntryIDs:
                liveDebitIDs.subtracting(authorizedDebitIDs),
            invalidPrepaidEvidenceEntryIDs: invalidPrepaidEvidenceIDs
        )
    }

    private static func invalidPrepaidEvidenceEntryIDs(
        plans: [AllowancePlan],
        invalidPlanIDs: Set<UUID>,
        accountsByID: [UUID: LedgerAccount],
        observesCancellation: Bool
    ) throws -> Set<UUID> {
        var result = Set<UUID>()
        var evidenceCount = 0
        for (planOffset, plan) in plans.enumerated() {
            if observesCancellation, planOffset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard invalidPlanIDs.contains(plan.id) else { continue }
            guard requiresLinkedUsage(plan, accountsByID: accountsByID) else {
                continue
            }
            for usage in plan.usages {
                if observesCancellation, evidenceCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                evidenceCount += 1
                if let entryID = usage.linkedJournalEntryID {
                    result.insert(entryID)
                }
            }
            for reconciliation in plan.reconciliations {
                if observesCancellation, evidenceCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                evidenceCount += 1
                if let entryID = reconciliation.linkedJournalEntryID {
                    result.insert(entryID)
                }
            }
        }
        return result
    }

    private static func authorizedRestrictedDebitEntryIDs(
        _ evidenceByEntryID: [UUID: [EvidenceAssessment]],
        invalidPlanIDs: Set<UUID>,
        observesCancellation: Bool
    ) throws -> Set<UUID> {
        var result = Set<UUID>()
        for (offset, item) in evidenceByEntryID.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let (entryID, evidence) = item
            guard evidence.count == 1,
                  let owner = evidence.first,
                  owner.isValid,
                  owner.authorizesRestrictedDebit,
                  !invalidPlanIDs.contains(owner.planID) else { continue }
            result.insert(entryID)
        }
        return result
    }

    static func invalidPlanIDs(
        plans: [AllowancePlan],
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry]
    ) throws -> Set<UUID> {
        try validationResult(
            plans: plans,
            accountsByID: accountsByID,
            entriesByID: entriesByID
        ).invalidPlanIDs
    }

    static func requireValid(
        plans: [AllowancePlan],
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry]
    ) throws {
        let result = try validationResult(
            plans: plans,
            accountsByID: accountsByID,
            entriesByID: entriesByID
        )
        guard result.invalidPlanIDs.isEmpty,
              result.unauthorizedRestrictedDebitEntryIDs.isEmpty,
              result.invalidPrepaidEvidenceEntryIDs.isEmpty else {
            throw AppModelError.invalidBook
        }
    }

    static func expiryFingerprint(
        planID: UUID,
        policyRevisionID: UUID,
        periodEnd: Date
    ) -> String {
        [
            planID.uuidString,
            policyRevisionID.uuidString,
            String(periodEnd.timeIntervalSinceReferenceDate)
        ].joined(separator: ":")
    }

    static func expiryOriginContext(
        plan: AllowancePlan,
        periodStart: Date,
        periodEnd: Date
    ) -> TransactionOriginContext {
        let zoneID = plan.policy(at: periodStart)?.timeZoneIdentifier
            ?? plan.timeZoneIdentifier
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: zoneID
        )
        return .capture(
            for: periodEnd,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }
}

private extension AllowanceJournalIntegrity {
    struct EvidenceAssessment {
        let planID: UUID
        let isValid: Bool
        let authorizesRestrictedDebit: Bool
    }

    static func assessUsages(
        _ plan: AllowancePlan,
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry],
        evidenceByEntryID: inout [UUID: [EvidenceAssessment]],
        invalidPlanIDs: inout Set<UUID>,
        observesCancellation: Bool
    ) throws {
        for (offset, usage) in plan.usages.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let entryID = usage.linkedJournalEntryID else {
                if requiresLinkedUsage(plan, accountsByID: accountsByID) {
                    invalidPlanIDs.insert(plan.id)
                }
                continue
            }
            let assessment: EvidenceAssessment
            do {
                assessment = try usageAssessment(
                    usage,
                    plan: plan,
                    entry: entriesByID[entryID],
                    accountsByID: accountsByID,
                    observesCancellation: observesCancellation
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A decoded journal entry can be individually valid while a
                // filtered subset of its positive expense postings exceeds
                // MoneyUp's checked Decimal aggregation envelope. Treat that
                // evidence as invalid instead of letting one hostile claim
                // abort best-effort book recovery.
                assessment = EvidenceAssessment(
                    planID: plan.id,
                    isValid: false,
                    authorizesRestrictedDebit: false
                )
            }
            evidenceByEntryID[entryID, default: []].append(assessment)
            if !assessment.isValid { invalidPlanIDs.insert(plan.id) }
        }
    }

    static func assessReconciliations(
        _ plan: AllowancePlan,
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry],
        evidenceByEntryID: inout [UUID: [EvidenceAssessment]],
        invalidPlanIDs: inout Set<UUID>,
        openingBalancesAccountID: UUID?,
        observesCancellation: Bool
    ) throws {
        for (offset, reconciliation) in plan.reconciliations.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let entryID = reconciliation.linkedJournalEntryID
            let isValid = reconciliationIsValid(
                reconciliation,
                plan: plan,
                entry: entryID.flatMap { entriesByID[$0] },
                accountsByID: accountsByID,
                openingBalancesAccountID: openingBalancesAccountID
            )
            if let entryID {
                evidenceByEntryID[entryID, default: []].append(
                    EvidenceAssessment(
                        planID: plan.id,
                        isValid: isValid,
                        authorizesRestrictedDebit: isValid
                            && reconciliation.expired.amount > .zero
                    )
                )
            }
            if !isValid { invalidPlanIDs.insert(plan.id) }
        }
    }

    static func requiresLinkedUsage(
        _ plan: AllowancePlan,
        accountsByID: [UUID: LedgerAccount]
    ) -> Bool {
        guard plan.fundingMode == .prepaidAsset,
              let accountID = plan.linkedAccountID else { return false }
        return accountsByID[accountID]?.accountType == .restrictedAllowance
    }

    static func usageAssessment(
        _ usage: AllowanceUsage,
        plan: AllowancePlan,
        entry: JournalEntry?,
        accountsByID: [UUID: LedgerAccount],
        observesCancellation: Bool
    ) throws -> EvidenceAssessment {
        guard let entry,
              entry.kind == .expense,
              entry.sourceSystem != expirySourceSystem,
              entry.occurredAt == usage.occurredAt,
              let policy = plan.policy(at: usage.occurredAt),
              usage.policyRevisionID == policy.id,
              usage.amount.currency == policy.amount.currency,
              try expenseEvidenceCoversUsage(
                  usage,
                  plan: plan,
                  entry: entry,
                  policy: policy,
                  accountsByID: accountsByID,
                  observesCancellation: observesCancellation
              ) else {
            return EvidenceAssessment(
                planID: plan.id,
                isValid: false,
                authorizesRestrictedDebit: false
            )
        }
        let authorizesDebit = prepaidDebitIsValid(
            usage,
            plan: plan,
            entry: entry,
            accountsByID: accountsByID
        )
        let hasRestrictedPosting = entry.postings.contains {
            accountsByID[$0.accountID]?.accountType == .restrictedAllowance
        }
        let isCurrentPrepaid = requiresLinkedUsage(
            plan,
            accountsByID: accountsByID
        )
        let postingSemanticsAreValid = isCurrentPrepaid
            ? authorizesDebit : !hasRestrictedPosting
        return EvidenceAssessment(
            planID: plan.id,
            isValid: postingSemanticsAreValid,
            authorizesRestrictedDebit: authorizesDebit
        )
    }

    static func expenseEvidenceCoversUsage(
        _ usage: AllowanceUsage,
        plan: AllowancePlan,
        entry: JournalEntry,
        policy: AllowancePolicyRevision,
        accountsByID: [UUID: LedgerAccount],
        observesCancellation: Bool
    ) throws -> Bool {
        let eligible = entry.postings.filter { posting in
            posting.money.amount > .zero
                && posting.money.currency == usage.amount.currency
                && accountsByID[posting.accountID]?.kind == .expense
                && policy.accepts(categoryID: posting.accountID)
        }
        guard !eligible.isEmpty else { return false }
        let coveredPostings = usage.categoryID.map { categoryID in
            eligible.filter { $0.accountID == categoryID }
        } ?? eligible
        guard try total(
            coveredPostings,
            observesCancellation: observesCancellation
        ) >= usage.amount.amount else { return false }
        return planCategoryIsExact(
            usage: usage,
            eligiblePostings: eligible,
            isGrandfathered: plan.hasGrandfatheredActivity
        )
    }

    static func planCategoryIsExact(
        usage: AllowanceUsage,
        eligiblePostings: [Posting],
        isGrandfathered: Bool
    ) -> Bool {
        if isGrandfathered {
            return usage.categoryID.map { categoryID in
                eligiblePostings.contains { $0.accountID == categoryID }
            } ?? true
        }
        let exactCategoryID = eligiblePostings.count == 1
            ? eligiblePostings[0].accountID : nil
        return usage.categoryID == exactCategoryID
    }

    static func total(
        _ postings: [Posting],
        observesCancellation: Bool
    ) throws -> Decimal {
        var amount = Decimal.zero
        for (offset, posting) in postings.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            amount = try CheckedDecimal.adding(amount, posting.money.amount)
        }
        return amount
    }

    static func prepaidDebitIsValid(
        _ usage: AllowanceUsage,
        plan: AllowancePlan,
        entry: JournalEntry,
        accountsByID: [UUID: LedgerAccount]
    ) -> Bool {
        guard plan.fundingMode == .prepaidAsset,
              let accountID = plan.linkedAccountID,
              let account = accountsByID[accountID],
              account.kind == .asset,
              account.accountType == .restrictedAllowance,
              account.currency == usage.amount.currency else { return false }
        let restricted = entry.postings.filter {
            accountsByID[$0.accountID]?.accountType == .restrictedAllowance
        }
        return restricted.count == 1
            && restricted[0].accountID == accountID
            && restricted[0].money == usage.amount.negated
    }

    static func reconciliationIsValid(
        _ reconciliation: AllowanceReconciliation,
        plan: AllowancePlan,
        entry: JournalEntry?,
        accountsByID: [UUID: LedgerAccount],
        openingBalancesAccountID: UUID?
    ) -> Bool {
        guard plan.fundingMode == .prepaidAsset,
              let accountID = plan.linkedAccountID,
              let account = accountsByID[accountID],
              account.kind == .asset,
              account.accountType == .restrictedAllowance,
              account.currency == reconciliation.expired.currency,
              let policy = plan.policy(at: reconciliation.periodStart),
              reconciliation.policyRevisionID == policy.id,
              policy.rolloverRule != .full else { return false }
        if reconciliation.expired.amount == .zero {
            return reconciliation.linkedJournalEntryID == nil && entry == nil
        }
        guard reconciliation.expired.amount > .zero,
              reconciliation.linkedJournalEntryID != nil,
              let entry,
              entry.kind == .adjustment,
              entry.occurredAt == reconciliation.periodEnd,
              entry.sourceSystem == expirySourceSystem,
              entry.sourceFingerprint == expiryFingerprint(
                  planID: plan.id,
                  policyRevisionID: reconciliation.policyRevisionID,
                  periodEnd: reconciliation.periodEnd
              ),
              entry.originContext == expiryOriginContext(
                  plan: plan,
                  periodStart: reconciliation.periodStart,
                  periodEnd: reconciliation.periodEnd
              ),
              let openingBalancesAccountID,
              entry.postings.count == 2 else { return false }
        let restricted = entry.postings.filter { $0.accountID == accountID }
        let equity = entry.postings.filter {
            $0.accountID == openingBalancesAccountID
        }
        return restricted.count == 1
            && restricted[0].money == reconciliation.expired.negated
            && equity.count == 1
            && equity[0].money == reconciliation.expired
    }

    static func canonicalOpeningBalancesAccountID(
        _ accountsByID: [UUID: LedgerAccount],
        observesCancellation: Bool
    ) throws -> UUID? {
        var candidates: [LedgerAccount] = []
        for (offset, account) in accountsByID.values.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            if account.systemRole == .openingBalances {
                candidates.append(account)
            }
        }
        guard candidates.count == 1,
              let account = candidates.first,
              account.kind == .equity,
              account.currency == nil,
              account.accountType == nil,
              account.parentID == nil,
              !account.isArchived else { return nil }
        return account.id
    }

    static func restrictedDebitEntryIDs(
        in entries: Dictionary<UUID, JournalEntry>.Values,
        accountsByID: [UUID: LedgerAccount],
        observesCancellation: Bool
    ) throws -> Set<UUID> {
        var result = Set<UUID>()
        var postingCount = 0
        for entry in entries {
            for posting in entry.postings {
                if observesCancellation, postingCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                postingCount += 1
                if posting.money.amount < .zero,
                   accountsByID[posting.accountID]?.accountType
                    == .restrictedAllowance {
                    result.insert(entry.id)
                    break
                }
            }
        }
        return result
    }
}
