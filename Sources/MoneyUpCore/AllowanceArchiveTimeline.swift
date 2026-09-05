import Foundation

/// An immutable change in whether an allowance can be used. The implicit
/// state before the first transition is active (`isArchived == false`).
/// Keeping this timeline separate from policy revisions prevents a lifecycle
/// action from rewriting historical allowance summaries.
public struct AllowanceArchiveTransition: Codable, Equatable, Sendable {
    public let effectiveAt: Date
    public let isArchived: Bool

    public init(effectiveAt: Date, isArchived: Bool) throws {
        guard effectiveAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AllowancePlanError.invalidDate
        }
        self.effectiveAt = effectiveAt
        self.isArchived = isArchived
    }
}

extension AllowancePlan {
    static let currentArchiveTimelineVersion = 1

    static func decodedArchiveState(
        from container: KeyedDecodingContainer<CodingKeys>,
        startsAt: Date,
        usages: [AllowanceUsage],
        reconciliations: [AllowanceReconciliation]
    ) throws -> (isArchived: Bool, transitions: [AllowanceArchiveTransition]) {
        let hasVersion = container.contains(.archiveTimelineVersion)
        let hasTimeline = container.contains(.archiveTransitions)
        if hasVersion {
            guard try container.decodeNil(forKey: .archiveTimelineVersion) == false,
                  try container.decode(
                      Int.self,
                      forKey: .archiveTimelineVersion
                  ) == currentArchiveTimelineVersion,
                  hasTimeline,
                  try container.decodeNil(forKey: .archiveTransitions) == false,
                  container.contains(.isArchived),
                  try container.decodeNil(forKey: .isArchived) == false else {
                throw AllowancePlanError.invalidPolicyRevision
            }
        } else if hasTimeline {
            throw AllowancePlanError.invalidPolicyRevision
        }
        if container.contains(.isArchived),
           try container.decodeNil(forKey: .isArchived) {
            throw AllowancePlanError.invalidPolicyRevision
        }
        let supplied = hasTimeline
            ? try container.decode(
                [AllowanceArchiveTransition].self,
                forKey: .archiveTransitions
            ) : nil
        let isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived)
            ?? supplied?.last?.isArchived ?? false
        guard supplied?.isEmpty != true || !isArchived else {
            throw AllowancePlanError.invalidPolicyRevision
        }
        if let supplied { return (isArchived, supplied) }
        guard isArchived else { return (false, []) }
        return (true, [try migratedLegacyArchiveTransition(
            startsAt: startsAt,
            usages: usages,
            reconciliations: reconciliations
        )])
    }

    static func migratedLegacyArchiveTransition(
        startsAt: Date,
        usages: [AllowanceUsage],
        reconciliations: [AllowanceReconciliation]
    ) throws -> AllowanceArchiveTransition {
        var effectiveSeconds = startsAt.timeIntervalSinceReferenceDate
        for usage in usages {
            effectiveSeconds = max(
                effectiveSeconds,
                usage.occurredAt.timeIntervalSinceReferenceDate.nextUp
            )
        }
        for reconciliation in reconciliations {
            effectiveSeconds = max(
                effectiveSeconds,
                reconciliation.periodEnd.timeIntervalSinceReferenceDate
            )
        }
        guard effectiveSeconds.isFinite else {
            throw AllowancePlanError.invalidDate
        }
        return try AllowanceArchiveTransition(
            effectiveAt: Date(timeIntervalSinceReferenceDate: effectiveSeconds),
            isArchived: true
        )
    }

    func isArchivedAt(_ date: Date) -> Bool {
        archiveTransitions.last { $0.effectiveAt <= date }?.isArchived ?? false
    }

    /// Whether at least one instant in this half-open cadence period was
    /// enabled. Archive is a pause, not proration: a partially enabled period
    /// keeps its single entitlement, while a wholly disabled period grants no
    /// new rollover value and creates no expiry expectation.
    func isActiveDuring(_ interval: DateInterval) -> Bool {
        guard interval.start < interval.end else { return false }
        if !isArchivedAt(interval.start) { return true }
        return archiveTransitions.contains { transition in
            !transition.isArchived
                && transition.effectiveAt >= interval.start
                && transition.effectiveAt < interval.end
        }
    }

    func archiveTransitionsForUpdate(
        isArchived candidateState: Bool,
        effectiveAt: Date,
        rewritesUnstartedDefinition: Bool,
        candidateStartsAt: Date
    ) throws -> [AllowanceArchiveTransition] {
        if rewritesUnstartedDefinition {
            return candidateState
                ? [try AllowanceArchiveTransition(
                    effectiveAt: candidateStartsAt,
                    isArchived: true
                )]
                : []
        }
        guard candidateState != isArchived else { return archiveTransitions }
        guard effectiveAt.timeIntervalSinceReferenceDate.isFinite,
              effectiveAt >= startsAt else {
            throw AllowancePlanError.invalidDate
        }

        var transitions = archiveTransitions
        if let latest = transitions.last {
            guard effectiveAt >= latest.effectiveAt else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            // Two opposite actions at the same instant cancel or replace one
            // another instead of producing an order-dependent pair.
            if effectiveAt == latest.effectiveAt {
                transitions.removeLast()
            }
        }
        let stateImmediatelyBefore = transitions.last?.isArchived ?? false
        if stateImmediatelyBefore != candidateState {
            guard transitions.count < Self.maximumArchiveTransitionCount else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            transitions.append(try AllowanceArchiveTransition(
                effectiveAt: effectiveAt,
                isArchived: candidateState
            ))
        }
        return transitions
    }
}
