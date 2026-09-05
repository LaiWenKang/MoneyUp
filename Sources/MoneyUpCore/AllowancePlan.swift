import Foundation

public enum AllowanceCadence: String, Codable, CaseIterable, Hashable, Sendable {
    case daily
    case weekdays
    case weekly
    case monthly
}

public enum AllowanceRolloverRule: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case capped
    case full
}

/// Describes what the allowance represents economically. The mode determines
/// whether a linked financial account is relevant; it does not create money.
public enum AllowanceFundingMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// A non-cash employer benefit or spending cap. It is planning-only.
    case benefitLimit = "benefit_limit"
    /// Value already held in a restricted card or wallet asset account.
    case prepaidAsset = "prepaid_asset"
    /// Eligible spending that may later be claimed from an employer.
    case reimbursement
}

/// Lifecycle evidence for an expense submitted under a reimbursement
/// allowance. Every status remains non-ledger evidence; approval never creates
/// cash or a receivable, and an actual reimbursement is recorded separately.
public enum AllowanceClaimStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pendingApproval = "pending_approval"
    case approved
    case reimbursed
    case rejected
}

/// Immutable, effective-dated policy evidence. Keeping prior revisions makes
/// historical allowance summaries stable when a user changes future rules.
public struct AllowancePolicyRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let effectiveAt: Date
    public let amount: Money
    public let cadence: AllowanceCadence
    public let timeZoneIdentifier: String
    public let eligibleCategoryIDs: Set<UUID>
    public let rolloverRule: AllowanceRolloverRule
    public let rolloverCap: Money?

    public init(
        id: UUID = UUID(),
        effectiveAt: Date,
        amount: Money,
        cadence: AllowanceCadence,
        timeZoneIdentifier: String,
        eligibleCategoryIDs: Set<UUID>,
        rolloverRule: AllowanceRolloverRule,
        rolloverCap: Money?
    ) throws {
        guard effectiveAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AllowancePlanError.invalidDate
        }
        guard amount.amount > .zero else {
            throw AllowancePlanError.amountMustBePositive
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw AllowancePlanError.invalidTimeZone
        }
        guard eligibleCategoryIDs.count <= AllowancePlan.maximumEligibleCategoryCount else {
            throw AllowancePlanError.tooManyCategories
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
        self.id = id
        self.effectiveAt = effectiveAt
        self.amount = amount
        self.cadence = cadence
        self.timeZoneIdentifier = timeZoneIdentifier
        self.eligibleCategoryIDs = eligibleCategoryIDs
        self.rolloverRule = rolloverRule
        self.rolloverCap = rolloverCap
    }

    public func accepts(categoryID: UUID?) -> Bool {
        eligibleCategoryIDs.isEmpty
            || categoryID.map(eligibleCategoryIDs.contains) == true
    }
}

public enum AllowancePlanError: Error, Equatable, Sendable {
    case emptyName
    case amountMustBePositive
    case invalidDate
    case invalidTimeZone
    case invalidRolloverCap
    case tooManyCategories
    case tooManyUsages
    case usageAmountMustBePositive
    case currencyMismatch
    case usageBeforeStart
    case usageAfterEnd
    case usageExceedsAvailable
    case duplicateLinkedUsage
    case invalidPolicyRevision
    case duplicateReconciliation
}

/// User-confirmed evidence that a provider expired prepaid value from its
/// restricted ledger asset. A zero amount explicitly closes the period
/// without consuming value that may have been funded for a newer period.
public struct AllowanceReconciliation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let policyRevisionID: UUID
    public let periodStart: Date
    public let periodEnd: Date
    public let expired: Money
    public let recordedAt: Date
    public let linkedJournalEntryID: UUID?

    public init(
        id: UUID = UUID(),
        policyRevisionID: UUID,
        periodStart: Date,
        periodEnd: Date,
        expired: Money,
        recordedAt: Date,
        linkedJournalEntryID: UUID?
    ) throws {
        guard periodStart.timeIntervalSinceReferenceDate.isFinite,
              periodEnd.timeIntervalSinceReferenceDate.isFinite,
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              periodStart < periodEnd,
              expired.amount >= .zero,
              (expired.amount > .zero) == (linkedJournalEntryID != nil) else {
            throw AllowancePlanError.invalidDate
        }
        self.id = id
        self.policyRevisionID = policyRevisionID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.expired = expired
        self.recordedAt = recordedAt
        self.linkedJournalEntryID = linkedJournalEntryID
    }
}

/// Optional evidence that a non-cash allowance was consumed. A linked journal
/// entry can record the user's actual out-of-pocket expense, while an
/// allowance-only usage deliberately has no effect on cash, income, or net
/// worth.
public struct AllowanceUsage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let amount: Money
    public let occurredAt: Date
    public let categoryID: UUID?
    public let linkedJournalEntryID: UUID?
    public let note: String?
    public let policyRevisionID: UUID?
    public let claimStatus: AllowanceClaimStatus?

    public init(
        id: UUID = UUID(),
        amount: Money,
        occurredAt: Date,
        categoryID: UUID? = nil,
        linkedJournalEntryID: UUID? = nil,
        note: String? = nil,
        policyRevisionID: UUID? = nil,
        claimStatus: AllowanceClaimStatus? = nil
    ) throws {
        guard amount.amount > .zero else {
            throw AllowancePlanError.usageAmountMustBePositive
        }
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AllowancePlanError.invalidDate
        }
        self.id = id
        self.amount = amount
        self.occurredAt = occurredAt
        self.categoryID = categoryID
        self.linkedJournalEntryID = linkedJournalEntryID
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = normalizedNote?.isEmpty == false ? normalizedNote : nil
        self.policyRevisionID = policyRevisionID
        self.claimStatus = claimStatus
    }

    internal enum CodingKeys: String, CodingKey {
        case id, amount, occurredAt, categoryID, linkedJournalEntryID, note
        case policyRevisionID, claimStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            amount: container.decode(Money.self, forKey: .amount),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            categoryID: container.decodeIfPresent(UUID.self, forKey: .categoryID),
            linkedJournalEntryID: container.decodeIfPresent(
                UUID.self,
                forKey: .linkedJournalEntryID
            ),
            note: container.decodeIfPresent(String.self, forKey: .note),
            policyRevisionID: container.decodeIfPresent(
                UUID.self,
                forKey: .policyRevisionID
            ),
            claimStatus: container.decodeIfPresent(
                AllowanceClaimStatus.self,
                forKey: .claimStatus
            )
        )
    }
}

public struct AllowanceSummary: Equatable, Sendable {
    public let interval: DateInterval?
    public let entitlement: Money
    public let used: Money
    public let remaining: Money
    public let isAvailableToday: Bool

    public init(
        interval: DateInterval?,
        entitlement: Money,
        used: Money,
        remaining: Money,
        isAvailableToday: Bool
    ) {
        self.interval = interval
        self.entitlement = entitlement
        self.used = used
        self.remaining = remaining
        self.isAvailableToday = isAvailableToday
    }
}

/// A completed policy period awaiting user confirmation. `amount` is only the
/// policy-derived maximum that could have expired; it is not evidence of a
/// grant, an account balance, or a provider adjustment.
public struct AllowanceExpiryRequirement: Equatable, Sendable {
    public let policyRevisionID: UUID
    public let interval: DateInterval
    public let amount: Money

    public init(
        policyRevisionID: UUID,
        interval: DateInterval,
        amount: Money
    ) {
        self.policyRevisionID = policyRevisionID
        self.interval = interval
        self.amount = amount
    }
}

/// Policy governing a benefit limit, restricted prepaid asset, or reimbursement
/// claim. Only the linked ledger account can represent money; this plan never
/// manufactures a balance of its own.
public struct AllowancePlan: Codable, Equatable, Identifiable, Sendable {
    public static let maximumEligibleCategoryCount = 1_024
    public static let maximumUsageCount = 4_096
    public static let maximumPolicyRevisionCount = 512
    public static let maximumReconciliationCount = 4_096
    public static let maximumArchiveTransitionCount = 512

    public let id: UUID
    public var name: String
    public var amount: Money
    public var cadence: AllowanceCadence
    public var fundingMode: AllowanceFundingMode
    /// Restricted asset account used only by a current prepaid workflow. Its
    /// compatibility is validated by the application against the ledger, whose
    /// balance remains authoritative; the allowance never duplicates it.
    public var linkedAccountID: UUID?
    public var startsAt: Date
    public var endsAt: Date?
    public var timeZoneIdentifier: String
    public var eligibleCategoryIDs: Set<UUID>
    public var rolloverRule: AllowanceRolloverRule
    public var rolloverCap: Money?
    public private(set) var usages: [AllowanceUsage]
    public private(set) var policyRevisions: [AllowancePolicyRevision]
    public private(set) var reconciliations: [AllowanceReconciliation]
    /// Prior-schema activity that is safe to report but not reinterpret under
    /// rules that did not exist when it was recorded.
    public private(set) var hasGrandfatheredActivity: Bool
    /// Current lifecycle state used by list filtering and write guards.
    public private(set) var isArchived: Bool
    /// Effective-dated lifecycle evidence used by historical summaries. The
    /// first transition is always an archive because the baseline is active.
    public private(set) var archiveTransitions: [AllowanceArchiveTransition]
    /// Persisted format provenance paired with the lifecycle evidence so a
    /// partially damaged current payload fails closed instead of downgrading.
    private let archiveTimelineVersion: Int

    public init(
        id: UUID = UUID(),
        name: String,
        amount: Money,
        cadence: AllowanceCadence,
        fundingMode: AllowanceFundingMode = .benefitLimit,
        linkedAccountID: UUID? = nil,
        startsAt: Date,
        endsAt: Date? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        eligibleCategoryIDs: Set<UUID> = [],
        rolloverRule: AllowanceRolloverRule = .none,
        rolloverCap: Money? = nil,
        usages: [AllowanceUsage] = [],
        policyRevisions: [AllowancePolicyRevision] = [],
        reconciliations: [AllowanceReconciliation] = [],
        hasGrandfatheredActivity: Bool = false,
        isArchived: Bool = false,
        archiveTransitions: [AllowanceArchiveTransition] = []
    ) throws {
        let normalizedName = try Self.validatedDefinitionName(
            name,
            amount: amount,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZoneIdentifier: timeZoneIdentifier,
            eligibleCategoryIDs: eligibleCategoryIDs,
            rolloverRule: rolloverRule,
            rolloverCap: rolloverCap,
            usageCount: usages.count,
            policyRevisionCount: policyRevisions.count,
            reconciliationCount: reconciliations.count
        )
        let revisions = try Self.validatedPolicyRevisions(
            policyRevisions,
            planID: id,
            amount: amount,
            cadence: cadence,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZoneIdentifier: timeZoneIdentifier,
            eligibleCategoryIDs: eligibleCategoryIDs,
            rolloverRule: rolloverRule,
            rolloverCap: rolloverCap
        )
        let validatedUsages = try Self.validatedUsages(
            usages: usages,
            revisions: revisions,
            fundingMode: fundingMode,
            grandfatheredActivity: hasGrandfatheredActivity,
            currency: amount.currency,
            startsAt: startsAt,
            endsAt: endsAt
        )
        try Self.validateReconciliations(
            reconciliations,
            revisions: revisions,
            currency: amount.currency,
            startsAt: startsAt,
            endsAt: endsAt
        )
        let validatedArchiveTransitions = try Self.validatedArchiveTransitions(
            archiveTransitions,
            startsAt: startsAt,
            currentState: isArchived
        )

        self.id = id
        self.name = normalizedName
        self.amount = amount
        self.cadence = cadence
        self.fundingMode = fundingMode
        self.linkedAccountID = linkedAccountID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.eligibleCategoryIDs = eligibleCategoryIDs
        self.rolloverRule = rolloverRule
        self.rolloverCap = rolloverCap
        self.usages = validatedUsages.sorted { $0.occurredAt < $1.occurredAt }
        self.policyRevisions = revisions
        self.reconciliations = reconciliations.sorted { $0.periodEnd < $1.periodEnd }
        self.hasGrandfatheredActivity = hasGrandfatheredActivity
        self.isArchived = isArchived
        self.archiveTransitions = validatedArchiveTransitions
        self.archiveTimelineVersion = Self.currentArchiveTimelineVersion
        guard self.usages.allSatisfy({ !isArchivedAt($0.occurredAt) }) else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        try validateReconciliationPeriods()
        try validateAllowancePeriodBalances(
            validatesUsage: !hasGrandfatheredActivity
        )
    }

}

public extension AllowancePlan {

    func policy(at date: Date) -> AllowancePolicyRevision? {
        policyRevisions.last { $0.effectiveAt <= date }
    }

    func isCategoryEligible(_ categoryID: UUID?, at date: Date) -> Bool {
        policy(at: date)?.accepts(categoryID: categoryID) == true
    }

    func addingUsage(_ usage: AllowanceUsage) throws -> AllowancePlan {
        guard !hasGrandfatheredActivity else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        guard usages.count < Self.maximumUsageCount else {
            throw AllowancePlanError.tooManyUsages
        }
        guard usage.amount.currency == amount.currency else {
            throw AllowancePlanError.currencyMismatch
        }
        guard usage.occurredAt >= startsAt else {
            throw AllowancePlanError.usageBeforeStart
        }
        guard endsAt.map({ usage.occurredAt < $0 }) ?? true else {
            throw AllowancePlanError.usageAfterEnd
        }
        guard usage.linkedJournalEntryID.map({ entryID in
            !usages.contains { $0.linkedJournalEntryID == entryID }
        }) ?? true else {
            throw AllowancePlanError.duplicateLinkedUsage
        }
        guard let policy = policy(at: usage.occurredAt),
              usage.policyRevisionID.map({ $0 == policy.id }) ?? true,
              (policy.accepts(categoryID: usage.categoryID)
                || (usage.categoryID == nil && usage.linkedJournalEntryID != nil)) else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        switch fundingMode {
        case .benefitLimit, .prepaidAsset:
            guard usage.claimStatus == nil else {
                throw AllowancePlanError.invalidPolicyRevision
            }
        case .reimbursement:
            guard usage.claimStatus != nil else {
                throw AllowancePlanError.invalidPolicyRevision
            }
        }
        let current = try summary(asOf: usage.occurredAt)
        guard current.isAvailableToday,
              usage.amount.amount <= max(current.remaining.amount, .zero) else {
            throw AllowancePlanError.usageExceedsAvailable
        }
        var copy = self
        copy.usages.append(usage)
        copy.usages.sort { $0.occurredAt < $1.occurredAt }
        return copy
    }

    func removingUsages(linkedTo entryID: UUID) throws -> AllowancePlan {
        guard !hasGrandfatheredActivity else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        var copy = self
        copy.usages.removeAll { $0.linkedJournalEntryID == entryID }
        return copy
    }

    func replacingUsage(
        linkedTo sourceEntryID: UUID,
        with usage: AllowanceUsage?
    ) throws -> AllowancePlan {
        let withoutOriginal = try removingUsages(linkedTo: sourceEntryID)
        guard let usage else { return withoutOriginal }
        return try withoutOriginal.addingUsage(usage)
    }

    func relinkingUsages(
        from sourceEntryID: UUID,
        to destinationEntryID: UUID
    ) throws -> AllowancePlan {
        guard !hasGrandfatheredActivity else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        var copy = self
        copy.usages = try usages.map { usage in
            guard usage.linkedJournalEntryID == sourceEntryID else { return usage }
            return try AllowanceUsage(
                id: usage.id,
                amount: usage.amount,
                occurredAt: usage.occurredAt,
                categoryID: usage.categoryID,
                linkedJournalEntryID: destinationEntryID,
                note: usage.note,
                policyRevisionID: usage.policyRevisionID,
                claimStatus: usage.claimStatus
            )
        }
        return copy
    }

    func updatingClaimStatus(
        usageID: UUID,
        to status: AllowanceClaimStatus
    ) throws -> AllowancePlan {
        guard !hasGrandfatheredActivity,
              fundingMode == .reimbursement,
              let index = usages.firstIndex(where: { $0.id == usageID }) else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        let current = usages[index]
        guard Self.isValidClaimTransition(
            from: current.claimStatus,
            to: status
        ) else { throw AllowancePlanError.invalidPolicyRevision }
        var copy = self
        copy.usages[index] = try AllowanceUsage(
            id: current.id,
            amount: current.amount,
            occurredAt: current.occurredAt,
            categoryID: current.categoryID,
            linkedJournalEntryID: current.linkedJournalEntryID,
            note: current.note,
            policyRevisionID: current.policyRevisionID,
            claimStatus: status
        )
        return copy
    }

    /// Applies mutable fields while preserving immutable policy history. Once
    /// the plan has started (or any activity exists), changed policy fields
    /// begin at the next cadence boundary after `effectiveAt`; old summaries
    /// continue to select the prior revision.
    func applyingUpdate(
        _ candidate: AllowancePlan,
        effectiveAt: Date
    ) throws -> AllowancePlan {
        guard !hasGrandfatheredActivity,
              candidate.id == id,
              candidate.amount.currency == amount.currency,
              effectiveAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        let preservesPolicyHistory = requiresEffectiveDatedUpdate(
            at: effectiveAt
        )
        if preservesPolicyHistory {
            guard candidate.startsAt == startsAt,
                  candidate.fundingMode == fundingMode,
                  candidate.linkedAccountID == linkedAccountID,
                  candidate.endsAt == endsAt else {
                throw AllowancePlanError.invalidPolicyRevision
            }
        }

        let revisions = preservesPolicyHistory
            ? try policyRevisionsForHistoryPreservingUpdate(
                candidate,
                effectiveAt: effectiveAt
            )
            : [try Self.policyRevision(
                from: candidate,
                effectiveAt: candidate.startsAt
            )]
        let archiveTransitions = try archiveTransitionsForUpdate(
            isArchived: candidate.isArchived,
            effectiveAt: effectiveAt,
            rewritesUnstartedDefinition: !preservesPolicyHistory,
            candidateStartsAt: candidate.startsAt
        )
        return try AllowancePlan(
            id: id,
            name: candidate.name,
            amount: candidate.amount,
            cadence: candidate.cadence,
            fundingMode: candidate.fundingMode,
            linkedAccountID: candidate.linkedAccountID,
            startsAt: candidate.startsAt,
            endsAt: candidate.endsAt,
            timeZoneIdentifier: candidate.timeZoneIdentifier,
            eligibleCategoryIDs: candidate.eligibleCategoryIDs,
            rolloverRule: candidate.rolloverRule,
            rolloverCap: candidate.rolloverCap,
            usages: usages,
            policyRevisions: revisions,
            reconciliations: reconciliations,
            hasGrandfatheredActivity: hasGrandfatheredActivity,
            isArchived: candidate.isArchived,
            archiveTransitions: archiveTransitions
        )
    }

    /// Whether an edit must retain effective policy evidence rather than
    /// rewriting the plan's baseline. An unstarted plan remains freely
    /// editable only while no usage or reconciliation has been recorded.
    func requiresEffectiveDatedUpdate(at editInstant: Date) -> Bool {
        editInstant >= startsAt
            || !usages.isEmpty
            || !reconciliations.isEmpty
    }

    func recordingReconciliation(
        _ reconciliation: AllowanceReconciliation
    ) throws -> AllowancePlan {
        guard !hasGrandfatheredActivity,
              reconciliations.count < Self.maximumReconciliationCount,
              reconciliation.expired.currency == amount.currency,
              policyRevisions.contains(where: {
                  $0.id == reconciliation.policyRevisionID
              }),
              !reconciliations.contains(where: {
                  $0.policyRevisionID == reconciliation.policyRevisionID
                      && $0.periodStart == reconciliation.periodStart
                      && $0.periodEnd == reconciliation.periodEnd
              }) else {
            throw AllowancePlanError.duplicateReconciliation
        }
        var copy = self
        copy.reconciliations.append(reconciliation)
        copy.reconciliations.sort { $0.periodEnd < $1.periodEnd }
        try Self.validateReconciliations(
            copy.reconciliations,
            revisions: copy.policyRevisions,
            currency: copy.amount.currency,
            startsAt: copy.startsAt,
            endsAt: copy.endsAt
        )
        try copy.validateReconciliationPeriods()
        try copy.validateAllowancePeriodBalances(
            validatesUsage: !copy.hasGrandfatheredActivity
        )
        return copy
    }

    func summary(asOf: Date) throws -> AllowanceSummary {
        guard let policy = policy(at: asOf) else {
            return AllowanceSummary(
                interval: nil,
                entitlement: .zero(currency: amount.currency),
                used: .zero(currency: amount.currency),
                remaining: .zero(currency: amount.currency),
                isAvailableToday: false
            )
        }
        var calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: policy.timeZoneIdentifier
        )
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let zero = Money.zero(currency: amount.currency)
        guard !isArchivedAt(asOf),
              asOf >= startsAt,
              endsAt.map({ asOf < $0 }) ?? true,
              let interval = activeInterval(
                  containing: asOf,
                  policy: policy,
                  calendar: calendar
              ) else {
            return AllowanceSummary(
                interval: nil,
                entitlement: zero,
                used: zero,
                remaining: zero,
                isAvailableToday: false
            )
        }

        let currentUsed = try totalUsage(in: interval, through: asOf)
        let carry = try carryEntering(interval.start, policy: policy, calendar: calendar)
        let entitlement = try policy.amount.adding(carry)
        let remaining = try entitlement.subtracting(currentUsed)
        return AllowanceSummary(
            interval: interval,
            entitlement: entitlement,
            used: currentUsed,
            remaining: remaining,
            isAvailableToday: true
        )
    }

    /// Returns each completed prepaid period that still needs explicit user
    /// confirmation. Policy math supplies a ceiling only; callers must never
    /// infer a ledger mutation from this list or an aggregate account balance.
    /// Periods use their immutable policy revision's reporting time zone.
    func expiryRequirements(asOf: Date) throws -> [AllowanceExpiryRequirement] {
        guard fundingMode == .prepaidAsset,
              asOf.timeIntervalSinceReferenceDate.isFinite else { return [] }
        var requirements: [AllowanceExpiryRequirement] = []
        for policy in policyRevisions where policy.rolloverRule != .full {
            var calendar = FinancialPeriodBoundary.gregorianCalendar(
                timeZoneIdentifier: policy.timeZoneIdentifier
            )
            calendar.locale = Locale(identifier: "en_US_POSIX")
            var cursor = policy.effectiveAt
            var attempts = 0
            while cursor < asOf {
                guard attempts < 10_000 else {
                    throw AllowancePlanError.invalidDate
                }
                attempts += 1
                guard let interval = activeInterval(
                    containing: cursor,
                    policy: policy,
                    calendar: calendar
                ) else {
                    guard policy.cadence == .weekdays,
                          let next = calendar.date(byAdding: .day, value: 1, to: cursor)
                    else { break }
                    cursor = next
                    continue
                }
                guard interval.end <= asOf else { break }
                guard isActiveDuring(interval) else {
                    cursor = interval.end
                    continue
                }
                if !reconciliations.contains(where: {
                    $0.policyRevisionID == policy.id
                        && $0.periodStart == interval.start
                        && $0.periodEnd == interval.end
                }) {
                    let used = try totalUsage(in: interval)
                    let carry = try carryEntering(
                        interval.start,
                        policy: policy,
                        calendar: calendar
                    )
                    let entitlement = try policy.amount.adding(carry)
                    let remaining = max(
                        .zero,
                        try CheckedDecimal.subtracting(
                            entitlement.amount,
                            used.amount
                        )
                    )
                    let protectedCarry = policy.rolloverRule == .capped
                        ? policy.rolloverCap?.amount ?? .zero
                        : .zero
                    let expiring = max(
                        .zero,
                        try CheckedDecimal.subtracting(remaining, protectedCarry)
                    )
                    requirements.append(AllowanceExpiryRequirement(
                        policyRevisionID: policy.id,
                        interval: interval,
                        amount: try Money(expiring, currency: amount.currency)
                    ))
                }
                cursor = interval.end
            }
        }
        return requirements.sorted { $0.interval.end < $1.interval.end }
    }
}

public extension AllowancePlan {
    internal enum CodingKeys: String, CodingKey {
        case id, name, amount, cadence, fundingMode, linkedAccountID
        case startsAt, endsAt, timeZoneIdentifier
        case eligibleCategoryIDs, rolloverRule, rolloverCap, usages
        case policyRevisions, reconciliations, hasGrandfatheredActivity, isArchived
        case archiveTransitions, archiveTimelineVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let decodedUsages = try container.decodeIfPresent(
                [AllowanceUsage].self,
                forKey: .usages
            ) ?? []
            let decodedRevisions = try container.decodeIfPresent(
                [AllowancePolicyRevision].self,
                forKey: .policyRevisions
            )
            let grandfathered = try container.decodeIfPresent(
                Bool.self,
                forKey: .hasGrandfatheredActivity
            ) ?? (decodedRevisions == nil && !decodedUsages.isEmpty)
            let decodedReconciliations = try container.decodeIfPresent(
                [AllowanceReconciliation].self,
                forKey: .reconciliations
            ) ?? []
            let decodedStartsAt = try container.decode(Date.self, forKey: .startsAt)
            let archive = try Self.decodedArchiveState(
                from: container,
                startsAt: decodedStartsAt,
                usages: decodedUsages,
                reconciliations: decodedReconciliations
            )
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                name: container.decode(String.self, forKey: .name),
                amount: container.decode(Money.self, forKey: .amount),
                cadence: container.decode(AllowanceCadence.self, forKey: .cadence),
                fundingMode: container.decodeIfPresent(
                    AllowanceFundingMode.self,
                    forKey: .fundingMode
                ) ?? .benefitLimit,
                linkedAccountID: container.decodeIfPresent(
                    UUID.self,
                    forKey: .linkedAccountID
                ),
                startsAt: decodedStartsAt,
                endsAt: container.decodeIfPresent(Date.self, forKey: .endsAt),
                timeZoneIdentifier: container.decode(
                    String.self,
                    forKey: .timeZoneIdentifier
                ),
                eligibleCategoryIDs: container.decodeIfPresent(
                    Set<UUID>.self,
                    forKey: .eligibleCategoryIDs
                ) ?? [],
                rolloverRule: container.decodeIfPresent(
                    AllowanceRolloverRule.self,
                    forKey: .rolloverRule
                ) ?? .none,
                rolloverCap: container.decodeIfPresent(
                    Money.self,
                    forKey: .rolloverCap
                ),
                usages: decodedUsages,
                policyRevisions: decodedRevisions ?? [],
                reconciliations: decodedReconciliations,
                hasGrandfatheredActivity: grandfathered,
                isArchived: archive.isArchived,
                archiveTransitions: archive.transitions
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Invalid allowance plan."
            )
        }
    }

    private func activeInterval(
        containing date: Date,
        policy: AllowancePolicyRevision,
        calendar: Calendar
    ) -> DateInterval? {
        let day = calendar.startOfDay(for: date)
        switch policy.cadence {
        case .daily:
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            return clipped(DateInterval(start: day, end: end), policy: policy)
        case .weekdays:
            let weekday = calendar.component(.weekday, from: day)
            guard weekday != 1 && weekday != 7,
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            return clipped(DateInterval(start: day, end: end), policy: policy)
        case .weekly:
            guard let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: policy.effectiveAt),
                to: day
            ).day else { return nil }
            let index = max(days, 0) / 7
            guard let start = calendar.date(
                byAdding: .day,
                value: index * 7,
                to: calendar.startOfDay(for: policy.effectiveAt)
            ), let end = calendar.date(byAdding: .day, value: 7, to: start) else {
                return nil
            }
            return clipped(DateInterval(start: start, end: end), policy: policy)
        case .monthly:
            return calendar.dateInterval(of: .month, for: date).flatMap {
                clipped($0, policy: policy)
            }
        }
    }

    private static func policyFields(
        of policy: AllowancePolicyRevision,
        match candidate: AllowancePlan
    ) -> Bool {
        policy.amount == candidate.amount
            && policy.cadence == candidate.cadence
            && policy.timeZoneIdentifier == candidate.timeZoneIdentifier
            && policy.eligibleCategoryIDs == candidate.eligibleCategoryIDs
            && policy.rolloverRule == candidate.rolloverRule
            && policy.rolloverCap == candidate.rolloverCap
    }

    private static func policyRevision(
        from candidate: AllowancePlan,
        effectiveAt: Date
    ) throws -> AllowancePolicyRevision {
        try AllowancePolicyRevision(
            effectiveAt: effectiveAt,
            amount: candidate.amount,
            cadence: candidate.cadence,
            timeZoneIdentifier: candidate.timeZoneIdentifier,
            eligibleCategoryIDs: candidate.eligibleCategoryIDs,
            rolloverRule: candidate.rolloverRule,
            rolloverCap: candidate.rolloverCap
        )
    }

    private func policyRevisionsForHistoryPreservingUpdate(
        _ candidate: AllowancePlan,
        effectiveAt: Date
    ) throws -> [AllowancePolicyRevision] {
        let policyReferenceInstant = max(effectiveAt, startsAt)
        guard let activePolicy = policy(at: policyReferenceInstant),
              let latest = policyRevisions.last else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        let usagePolicyIDs = usages.compactMap { usage in
            usage.policyRevisionID ?? policy(at: usage.occurredAt)?.id
        }
        let referencedPolicyIDs = Set(
            usagePolicyIDs
                + reconciliations.map(\.policyRevisionID)
        )
        let hasReferencedFuturePolicy = policyRevisions.contains {
            $0.effectiveAt > effectiveAt
                && referencedPolicyIDs.contains($0.id)
        }
        // Future-dated evidence makes its policy immutable before activation.
        if hasReferencedFuturePolicy {
            guard Self.policyFields(of: latest, match: candidate) else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            return policyRevisions
        }

        // Only unreferenced policies after this instant may be cancelled or
        // replaced. Effective policy identifiers remain historical evidence.
        var revisions = policyRevisions.filter {
            $0.effectiveAt <= policyReferenceInstant
        }
        guard !Self.policyFields(of: activePolicy, match: candidate) else {
            return revisions
        }
        let boundary = try nextPolicyBoundary(
            strictlyAfter: policyReferenceInstant,
            policy: activePolicy
        )
        guard boundary > policyReferenceInstant,
              boundary >= startsAt,
              candidate.endsAt.map({ boundary < $0 }) ?? true,
              !usages.contains(where: { $0.occurredAt >= boundary }) else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        revisions.append(try Self.policyRevision(
            from: candidate,
            effectiveAt: boundary
        ))
        return revisions
    }

    private func nextPolicyBoundary(
        strictlyAfter date: Date,
        policy: AllowancePolicyRevision
    ) throws -> Date {
        guard date >= policy.effectiveAt else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        var calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: policy.timeZoneIdentifier
        )
        calendar.locale = Locale(identifier: "en_US_POSIX")
        switch policy.cadence {
        case .daily:
            guard let boundary = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: date)
            ) else { throw AllowancePlanError.invalidDate }
            return boundary
        case .weekdays:
            let instantAfter = Date(
                timeIntervalSinceReferenceDate:
                    date.timeIntervalSinceReferenceDate.nextUp
            )
            return try nextWeekdayBoundary(
                onOrAfter: instantAfter,
                calendar: calendar
            )
        case .weekly:
            let anchor = calendar.startOfDay(for: policy.effectiveAt)
            let day = calendar.startOfDay(for: date)
            guard let elapsedDays = calendar.dateComponents(
                [.day],
                from: anchor,
                to: day
            ).day,
            let boundary = calendar.date(
                byAdding: .day,
                value: ((max(elapsedDays, 0) / 7) + 1) * 7,
                to: anchor
            ) else { throw AllowancePlanError.invalidDate }
            return boundary
        case .monthly:
            guard let boundary = calendar.dateInterval(
                of: .month,
                for: date
            )?.end else { throw AllowancePlanError.invalidDate }
            return boundary
        }
    }

    private func nextWeekdayBoundary(
        onOrAfter date: Date,
        calendar: Calendar
    ) throws -> Date {
        var candidate = calendar.startOfDay(for: date)
        if candidate < date {
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate)
            else { throw AllowancePlanError.invalidDate }
            candidate = next
        }
        for _ in 0..<8 {
            let weekday = calendar.component(.weekday, from: candidate)
            if weekday != 1 && weekday != 7 { return candidate }
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate)
            else { throw AllowancePlanError.invalidDate }
            candidate = next
        }
        throw AllowancePlanError.invalidDate
    }

    private func clipped(
        _ interval: DateInterval,
        policy: AllowancePolicyRevision
    ) -> DateInterval? {
        let nextPolicyStart = policyRevisions.first {
            $0.effectiveAt > policy.effectiveAt
        }?.effectiveAt
        let start = max(max(interval.start, startsAt), policy.effectiveAt)
        let planEnd = endsAt ?? interval.end
        let end = min(min(interval.end, planEnd), nextPolicyStart ?? interval.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func totalUsage(
        in interval: DateInterval,
        through asOf: Date? = nil
    ) throws -> Money {
        var total = Decimal.zero
        for usage in usages where usage.claimStatus != .rejected
            && (asOf.map { usage.occurredAt <= $0 } ?? true)
            && FinancialPeriodBoundary.contains(usage.occurredAt, in: interval) {
            total = try CheckedDecimal.adding(total, usage.amount.amount)
        }
        return try Money(total, currency: amount.currency)
    }

    private func validateReconciliationPeriods() throws {
        guard reconciliations.isEmpty || fundingMode == .prepaidAsset else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        for reconciliation in reconciliations {
            guard let policy = policyRevisions.first(where: {
                $0.id == reconciliation.policyRevisionID
            }) else { throw AllowancePlanError.invalidPolicyRevision }
            var calendar = FinancialPeriodBoundary.gregorianCalendar(
                timeZoneIdentifier: policy.timeZoneIdentifier
            )
            calendar.locale = Locale(identifier: "en_US_POSIX")
            guard let interval = activeInterval(
                containing: reconciliation.periodStart,
                policy: policy,
                calendar: calendar
            ), interval.start == reconciliation.periodStart,
               interval.end == reconciliation.periodEnd,
               isActiveDuring(interval),
               policy.rolloverRule != .full else {
                throw AllowancePlanError.invalidPolicyRevision
            }
        }
    }

    private func carryEntering(
        _ currentStart: Date,
        policy: AllowancePolicyRevision,
        calendar: Calendar
    ) throws -> Money {
        let transitionCarry = try carryFromPreviousPolicy(into: policy)
        if currentStart == policy.effectiveAt { return transitionCarry }
        guard policy.rolloverRule != .none else {
            return .zero(currency: amount.currency)
        }
        var entitlement = transitionCarry.amount
        var cursor = policy.effectiveAt
        var periods = 0
        while cursor < currentStart {
            guard periods < 10_000,
                  let interval = activeInterval(
                      containing: cursor,
                      policy: policy,
                      calendar: calendar
                  ) else {
                // Weekends have no weekday allowance; advance one civil day.
                guard policy.cadence == .weekdays,
                      let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                    throw AllowancePlanError.invalidDate
                }
                cursor = next
                continue
            }
            guard interval.start < currentStart else { break }
            if isActiveDuring(interval) {
                entitlement = try CheckedDecimal.adding(
                    entitlement,
                    policy.amount.amount
                )
                let used = try totalUsage(in: interval)
                entitlement = max(
                    .zero,
                    try CheckedDecimal.subtracting(entitlement, used.amount)
                )
                if policy.rolloverRule == .capped, let rolloverCap = policy.rolloverCap {
                    entitlement = min(entitlement, rolloverCap.amount)
                }
            }
            cursor = interval.end
            periods += 1
        }
        return try Money(entitlement, currency: amount.currency)
    }

    private func carryFromPreviousPolicy(
        into policy: AllowancePolicyRevision
    ) throws -> Money {
        guard let index = policyRevisions.firstIndex(where: { $0.id == policy.id }),
              index > policyRevisions.startIndex else {
            return .zero(currency: amount.currency)
        }
        let previous = policyRevisions[policyRevisions.index(before: index)]
        var calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: previous.timeZoneIdentifier
        )
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return try carryEntering(
            policy.effectiveAt,
            policy: previous,
            calendar: calendar
        )
    }
}
