import Foundation

private struct AllowanceArchiveValidationCursor {
    let transitions: [AllowanceArchiveTransition]
    var index = 0
    var isArchived = false

    mutating func isActive(during interval: DateInterval) -> Bool {
        while index < transitions.count,
              transitions[index].effectiveAt <= interval.start {
            isArchived = transitions[index].isArchived
            index += 1
        }
        var result = !isArchived
        while index < transitions.count,
              transitions[index].effectiveAt < interval.end {
            isArchived = transitions[index].isArchived
            if !isArchived { result = true }
            index += 1
        }
        return result
    }
}

private struct AllowanceUsagePeriodIndex {
    var amounts: [String: Decimal] = [:]
    var lastBoundary: Date?
}

extension AllowancePlan {
    /// Validates all persisted expiry ceilings in one chronological carry walk.
    /// The older per-reconciliation calculation repeatedly rescanned every
    /// prior period and usage, making synchronous decode multiplicative.
    func validateAllowancePeriodBalances(validatesUsage: Bool) throws {
        try Task.checkCancellation()
        guard validatesUsage || !reconciliations.isEmpty else { return }
        let usageIndex = try reconciliationUsageByPeriod()
        var reconciliationBoundary: Date?
        var reconciliationByPeriod: [String: AllowanceReconciliation] = [:]
        for (offset, reconciliation) in reconciliations.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            reconciliationBoundary = max(
                reconciliationBoundary ?? reconciliation.periodEnd,
                reconciliation.periodEnd
            )
            reconciliationByPeriod[Self.reconciliationKey(reconciliation)] =
                reconciliation
        }
        guard let lastBoundary = [
            usageIndex.lastBoundary,
            reconciliationBoundary
        ].compactMap({ $0 }).max() else { return }
        var archiveCursor = AllowanceArchiveValidationCursor(
            transitions: archiveTransitions
        )
        var carry = Decimal.zero
        var visitedPeriodCount = 0
        var validatedReconciliationCount = 0
        for index in policyRevisions.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let policy = policyRevisions[index]
            guard policy.effectiveAt < lastBoundary else { break }
            let nextPolicyStart = policyRevisions.indices.contains(index + 1)
                ? policyRevisions[index + 1].effectiveAt : nil
            let upperBound = min(nextPolicyStart ?? lastBoundary, lastBoundary)
            carry = try validateReconciliationCeilings(
                policy: policy,
                nextPolicyStart: nextPolicyStart,
                upperBound: upperBound,
                startingCarry: carry,
                usageByPeriod: usageIndex.amounts,
                reconciliationByPeriod: reconciliationByPeriod,
                validatesUsage: validatesUsage,
                archiveCursor: &archiveCursor,
                visitedPeriodCount: &visitedPeriodCount,
                validatedReconciliationCount: &validatedReconciliationCount
            )
        }
        guard validatedReconciliationCount == reconciliations.count else {
            throw AllowancePlanError.invalidPolicyRevision
        }
    }

    private func reconciliationUsageByPeriod() throws -> AllowanceUsagePeriodIndex {
        var result = AllowanceUsagePeriodIndex()
        for (offset, usage) in usages.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            guard usage.claimStatus != .rejected else { continue }
            guard let context = reconciliationPolicyContext(
                at: usage.occurredAt
            ) else { throw AllowancePlanError.invalidPolicyRevision }
            var calendar = FinancialPeriodBoundary.gregorianCalendar(
                timeZoneIdentifier: context.policy.timeZoneIdentifier
            )
            calendar.locale = Locale(identifier: "en_US_POSIX")
            guard let interval = reconciliationInterval(
                containing: usage.occurredAt,
                policy: context.policy,
                nextPolicyStart: context.nextPolicyStart,
                calendar: calendar
            ) else { throw AllowancePlanError.invalidDate }
            let key = Self.periodKey(
                policyID: context.policy.id,
                interval: interval
            )
            result.amounts[key] = try CheckedDecimal.adding(
                result.amounts[key] ?? .zero,
                usage.amount.amount
            )
            result.lastBoundary = max(
                result.lastBoundary ?? interval.end,
                interval.end
            )
        }
        return result
    }

    private func reconciliationPolicyContext(
        at date: Date
    ) -> (policy: AllowancePolicyRevision, nextPolicyStart: Date?)? {
        guard let index = policyRevisions.lastIndex(where: {
            $0.effectiveAt <= date
        }) else { return nil }
        let nextStart = policyRevisions.indices.contains(index + 1)
            ? policyRevisions[index + 1].effectiveAt : nil
        return (policyRevisions[index], nextStart)
    }

    private func validateReconciliationCeilings(
        policy: AllowancePolicyRevision,
        nextPolicyStart: Date?,
        upperBound: Date,
        startingCarry: Decimal,
        usageByPeriod: [String: Decimal],
        reconciliationByPeriod: [String: AllowanceReconciliation],
        validatesUsage: Bool,
        archiveCursor: inout AllowanceArchiveValidationCursor,
        visitedPeriodCount: inout Int,
        validatedReconciliationCount: inout Int
    ) throws -> Decimal {
        var calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: policy.timeZoneIdentifier
        )
        calendar.locale = Locale(identifier: "en_US_POSIX")
        var cursor = policy.effectiveAt
        var carry = startingCarry
        var cursorStepCount = 0
        while cursor < upperBound {
            if cursorStepCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            cursorStepCount += 1
            guard visitedPeriodCount < 10_000 else {
                throw AllowancePlanError.invalidDate
            }
            guard let interval = reconciliationInterval(
                containing: cursor,
                policy: policy,
                nextPolicyStart: nextPolicyStart,
                calendar: calendar
            ) else {
                guard policy.cadence == .weekdays,
                      let next = calendar.date(
                          byAdding: .day,
                          value: 1,
                          to: cursor
                      ) else { throw AllowancePlanError.invalidDate }
                cursor = next
                if policy.rolloverRule == .none { carry = .zero }
                continue
            }
            let isActive = archiveCursor.isActive(during: interval)
            carry = try validatedCarry(
                policy: policy,
                startingCarry: carry,
                isActive: isActive,
                validatesUsage: validatesUsage,
                used: usageByPeriod[Self.periodKey(
                    policyID: policy.id,
                    interval: interval
                )] ?? .zero,
                reconciliation: reconciliationByPeriod[
                    Self.reconciliationKey(
                        policyID: policy.id,
                        interval: interval
                    )
                ],
                validatedCount: &validatedReconciliationCount
            )
            cursor = interval.end
            visitedPeriodCount += 1
        }
        return carry
    }

    private func validatedCarry(
        policy: AllowancePolicyRevision,
        startingCarry: Decimal,
        isActive: Bool,
        validatesUsage: Bool,
        used: Decimal,
        reconciliation: AllowanceReconciliation?,
        validatedCount: inout Int
    ) throws -> Decimal {
        guard isActive else {
            if reconciliation != nil {
                throw AllowancePlanError.invalidPolicyRevision
            }
            return policy.rolloverRule == .none ? .zero : startingCarry
        }
        let entitlement = try CheckedDecimal.adding(
            startingCarry,
            policy.amount.amount
        )
        guard !validatesUsage || used <= entitlement else {
            throw AllowancePlanError.usageExceedsAvailable
        }
        let remaining = max(
            .zero,
            try CheckedDecimal.subtracting(entitlement, used)
        )
        if let reconciliation {
            let protected = policy.rolloverRule == .capped
                ? policy.rolloverCap?.amount ?? .zero : .zero
            let ceiling = max(
                .zero,
                try CheckedDecimal.subtracting(remaining, protected)
            )
            guard reconciliation.expired.amount <= ceiling else {
                throw AllowancePlanError.invalidPolicyRevision
            }
            validatedCount += 1
        }
        switch policy.rolloverRule {
        case .none: return .zero
        case .capped: return min(remaining, policy.rolloverCap?.amount ?? .zero)
        case .full: return remaining
        }
    }

    private func reconciliationInterval(
        containing date: Date,
        policy: AllowancePolicyRevision,
        nextPolicyStart: Date?,
        calendar: Calendar
    ) -> DateInterval? {
        let day = calendar.startOfDay(for: date)
        let raw: DateInterval?
        switch policy.cadence {
        case .daily:
            raw = calendar.date(byAdding: .day, value: 1, to: day).map {
                DateInterval(start: day, end: $0)
            }
        case .weekdays:
            let weekday = calendar.component(.weekday, from: day)
            raw = weekday == 1 || weekday == 7 ? nil
                : calendar.date(byAdding: .day, value: 1, to: day).map {
                    DateInterval(start: day, end: $0)
                }
        case .weekly:
            raw = reconciliationWeeklyInterval(
                containing: day,
                policy: policy,
                calendar: calendar
            )
        case .monthly:
            raw = calendar.dateInterval(of: .month, for: date)
        }
        guard let raw else { return nil }
        let start = max(max(raw.start, startsAt), policy.effectiveAt)
        let end = min(
            min(raw.end, endsAt ?? raw.end),
            nextPolicyStart ?? raw.end
        )
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func reconciliationWeeklyInterval(
        containing day: Date,
        policy: AllowancePolicyRevision,
        calendar: Calendar
    ) -> DateInterval? {
        let anchor = calendar.startOfDay(for: policy.effectiveAt)
        guard let days = calendar.dateComponents(
            [.day],
            from: anchor,
            to: day
        ).day else { return nil }
        let index = max(days, 0) / 7
        guard let start = calendar.date(
            byAdding: .day,
            value: index * 7,
            to: anchor
        ), let end = calendar.date(
            byAdding: .day,
            value: 7,
            to: start
        ) else { return nil }
        return DateInterval(start: start, end: end)
    }
}

private extension AllowancePlan {
    static func reconciliationKey(
        policyID: UUID,
        interval: DateInterval
    ) -> String {
        [
            policyID.uuidString,
            String(interval.start.timeIntervalSinceReferenceDate),
            String(interval.end.timeIntervalSinceReferenceDate)
        ].joined(separator: "|")
    }
}
