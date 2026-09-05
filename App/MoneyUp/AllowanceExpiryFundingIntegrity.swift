import Foundation
import MoneyUpCore

/// Expiry is authorized only by stored value that existed strictly before the
/// policy boundary. Journal entries sharing the boundary remain atomic for the
/// general ledger invariant, but a same-instant top-up cannot backfill expiry.
enum AllowanceExpiryFundingIntegrity {
    private struct Claim {
        let planID: UUID
        let amount: Decimal
        let currency: CurrencyCode
    }

    private struct AccountMetadata {
        var planIDs = Set<UUID>()
        var currency: CurrencyCode?
        var hasMixedCurrencies = false
    }

    static func invalidPlanIDs(
        plans: [AllowancePlan],
        invalidPlanIDs: Set<UUID>,
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry],
        suppliedRestrictedEvents: [LedgerPostingEvent]?,
        excludingEntryIDs: Set<UUID>,
        observesCancellation: Bool
    ) throws -> Set<UUID> {
        let claims = try claimsByAccountAndBoundary(
            plans: plans,
            invalidPlanIDs: invalidPlanIDs,
            accountsByID: accountsByID,
            observesCancellation: observesCancellation
        )
        guard !claims.isEmpty else { return [] }
        var restrictedAccountIDs = Set<UUID>()
        for (offset, accountID) in claims.keys.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            restrictedAccountIDs.insert(accountID)
        }
        let events = try restrictedEvents(
            suppliedRestrictedEvents,
            entriesByID: entriesByID,
            restrictedAccountIDs: restrictedAccountIDs,
            observesCancellation: observesCancellation
        )
        var eventsByAccount: [UUID: [LedgerPostingEvent]] = [:]
        for (offset, event) in events.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard claims[event.posting.accountID] != nil,
                  !excludingEntryIDs.contains(event.entryID) else { continue }
            eventsByAccount[event.posting.accountID, default: []].append(event)
        }
        return try invalidPlanIDs(
            claims: claims,
            eventsByAccount: eventsByAccount,
            observesCancellation: observesCancellation
        )
    }

    private static func claimsByAccountAndBoundary(
        plans: [AllowancePlan],
        invalidPlanIDs: Set<UUID>,
        accountsByID: [UUID: LedgerAccount],
        observesCancellation: Bool
    ) throws -> [UUID: [TimeInterval: [Claim]]] {
        var result: [UUID: [TimeInterval: [Claim]]] = [:]
        var reconciliationCount = 0
        for (planOffset, plan) in plans.enumerated() {
            if observesCancellation, planOffset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard !invalidPlanIDs.contains(plan.id),
                  plan.fundingMode == .prepaidAsset,
                  let accountID = plan.linkedAccountID,
                  accountsByID[accountID]?.accountType == .restrictedAllowance,
                  let currency = accountsByID[accountID]?.currency else { continue }
            for reconciliation in plan.reconciliations {
                if observesCancellation,
                   reconciliationCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                reconciliationCount += 1
                guard reconciliation.expired.amount > .zero else { continue }
                result[accountID, default: [:]][
                    reconciliation.periodEnd.timeIntervalSince1970,
                    default: []
                ].append(Claim(
                    planID: plan.id,
                    amount: reconciliation.expired.amount,
                    currency: currency
                ))
            }
        }
        return result
    }

    private static func restrictedEvents(
        _ supplied: [LedgerPostingEvent]?,
        entriesByID: [UUID: JournalEntry],
        restrictedAccountIDs: Set<UUID>,
        observesCancellation: Bool
    ) throws -> [LedgerPostingEvent] {
        if let supplied { return supplied }
        var result: [LedgerPostingEvent] = []
        var postingCount = 0
        for entry in entriesByID.values {
            for posting in entry.postings {
                if observesCancellation, postingCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                postingCount += 1
                guard restrictedAccountIDs.contains(posting.accountID) else {
                    continue
                }
                result.append(LedgerPostingEvent(
                    entryID: entry.id,
                    occurredAt: entry.occurredAt,
                    originDayKey: 0,
                    posting: posting
                ))
            }
        }
        return result
    }

    private static func invalidPlanIDs(
        claims: [UUID: [TimeInterval: [Claim]]],
        eventsByAccount: [UUID: [LedgerPostingEvent]],
        observesCancellation: Bool
    ) throws -> Set<UUID> {
        let accountIDs = claims.keys.sorted {
            $0.uuidString < $1.uuidString
        }
        if observesCancellation { try Task.checkCancellation() }
        var result = Set<UUID>()
        for (offset, accountID) in accountIDs.enumerated() {
            if observesCancellation, offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard let claimsByBoundary = claims[accountID] else { continue }
            result.formUnion(try invalidPlanIDs(
                claimsByBoundary: claimsByBoundary,
                events: eventsByAccount[accountID] ?? [],
                observesCancellation: observesCancellation
            ))
        }
        return result
    }

    private static func invalidPlanIDs(
        claimsByBoundary: [TimeInterval: [Claim]],
        events: [LedgerPostingEvent],
        observesCancellation: Bool
    ) throws -> Set<UUID> {
        let metadata = try accountMetadata(
            claimsByBoundary,
            observesCancellation: observesCancellation
        )
        guard let currency = metadata.currency,
              !metadata.hasMixedCurrencies else { return metadata.planIDs }
        var events = events
        events.sort {
            let lhs = $0.occurredAt.timeIntervalSince1970
            let rhs = $1.occurredAt.timeIntervalSince1970
            if lhs != rhs {
                return lhs < rhs
            }
            return $0.entryID.uuidString < $1.entryID.uuidString
        }
        if observesCancellation { try Task.checkCancellation() }
        let boundaries = claimsByBoundary.keys.sorted()
        if observesCancellation { try Task.checkCancellation() }
        var eventIndex = 0
        var balance = Decimal.zero
        for boundary in boundaries {
            while eventIndex < events.count,
                  events[eventIndex].occurredAt.timeIntervalSince1970
                    < boundary {
                if observesCancellation, eventIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                let posting = events[eventIndex].posting
                guard posting.money.currency == currency else {
                    return metadata.planIDs
                }
                do {
                    balance = try CheckedDecimal.adding(
                        balance,
                        posting.money.amount
                    )
                } catch {
                    return metadata.planIDs
                }
                eventIndex += 1
            }
            let boundaryClaims = claimsByBoundary[boundary] ?? []
            guard let required = try claimTotal(
                boundaryClaims,
                observesCancellation: observesCancellation
            ) else { return metadata.planIDs }
            guard required <= balance else {
                return try planIDs(
                    in: boundaryClaims,
                    observesCancellation: observesCancellation
                )
            }
        }
        return []
    }

    private static func accountMetadata(
        _ claimsByBoundary: [TimeInterval: [Claim]],
        observesCancellation: Bool
    ) throws -> AccountMetadata {
        var result = AccountMetadata()
        var claimCount = 0
        for claims in claimsByBoundary.values {
            for claim in claims {
                if observesCancellation, claimCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                claimCount += 1
                result.planIDs.insert(claim.planID)
                if let currency = result.currency,
                   currency != claim.currency {
                    result.hasMixedCurrencies = true
                } else {
                    result.currency = claim.currency
                }
            }
        }
        return result
    }

    private static func claimTotal(
        _ claims: [Claim],
        observesCancellation: Bool
    ) throws -> Decimal? {
        var result = Decimal.zero
        for (offset, claim) in claims.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            do {
                result = try CheckedDecimal.adding(result, claim.amount)
            } catch {
                return nil
            }
        }
        return result
    }

    private static func planIDs(
        in claims: [Claim],
        observesCancellation: Bool
    ) throws -> Set<UUID> {
        var result = Set<UUID>()
        for (offset, claim) in claims.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            result.insert(claim.planID)
        }
        return result
    }
}
