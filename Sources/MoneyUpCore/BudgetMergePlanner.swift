import Foundation

public enum BudgetMergeError: Error, Equatable {
    case missingCategory
    case overallocatedEnvelope
    case rolloverRequiresReview
}

/// Converts only the two reviewed merge endpoints into direct allocations.
/// Subtracting their child allocations first conserves the total when one
/// endpoint contains the other; adding their visible caps would double-count.
public enum BudgetMergePlanner {
    public static func mergedNode(
        sourceID: UUID,
        targetID: UUID,
        nodes: [BudgetNode],
        currency: CurrencyCode
    ) throws -> BudgetNode {
        guard let source = nodes.first(where: { $0.id == sourceID }),
              var target = nodes.first(where: { $0.id == targetID }),
              sourceID != targetID else { throw BudgetMergeError.missingCategory }
        target.limit = try combinedDirectLimit(
            sourceID: sourceID, targetID: targetID, nodes: nodes, currency: currency
        )
        target.allocationMode = .automatic
        if target.purpose == .unclassified { target.purpose = source.purpose }
        if target.rolloverRule == .none {
            target.rolloverRule = source.rolloverRule
            target.rolloverStartedAt = source.rolloverStartedAt
        }
        let scopes = (source.monthlyAllocations + target.monthlyAllocations)
        var mergedScopes: [MonthlyBudgetAllocation] = []
        for scope in scopes where !mergedScopes.contains(where: {
            $0.month == scope.month && $0.currency == scope.currency
        }) {
            let resolved = nodes.map { $0.resolved(for: scope.month, currency: scope.currency) }
            let limit = try combinedDirectLimit(
                sourceID: sourceID, targetID: targetID, nodes: resolved, currency: scope.currency
            )
            let resolvedTarget = target.resolved(for: scope.month, currency: scope.currency)
            mergedScopes.append(try MonthlyBudgetAllocation(
                month: scope.month, currency: scope.currency, limit: limit,
                mode: .automatic, purpose: resolvedTarget.purpose
            ))
        }
        target.monthlyAllocations = mergedScopes.sorted {
            $0.month == $1.month ? $0.currency < $1.currency : $0.month < $1.month
        }
        return target
    }

    private static func combinedDirectLimit(
        sourceID: UUID,
        targetID: UUID,
        nodes: [BudgetNode],
        currency: CurrencyCode
    ) throws -> Money? {
        let tree = try BudgetTree(currency: currency, nodes: nodes)
        let aggregation = try BudgetAggregation(currency: currency, nodes: tree.nodes, effectiveLimits: [:])
        let selected = tree.nodes.filter { $0.id == sourceID || $0.id == targetID }
        var combined: Money?
        for node in selected {
            guard let limit = node.limit else { continue }
            let direct: Money
            if node.allocationMode == .fixedTotal, nodes.contains(where: { $0.parentID == node.id }) {
                let children = aggregation.childrenTotals[node.id] ?? .zero(currency: currency)
                guard node.rolloverRule == .none else { throw BudgetMergeError.rolloverRequiresReview }
                direct = try limit.subtracting(children)
                guard direct.amount >= .zero else { throw BudgetMergeError.overallocatedEnvelope }
            } else {
                direct = limit
            }
            combined = try (combined ?? .zero(currency: currency)).adding(direct)
        }
        return combined
    }
}
