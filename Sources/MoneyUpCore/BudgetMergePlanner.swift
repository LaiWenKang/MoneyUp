import Foundation

public enum BudgetMergeError: Error, Equatable {
    case missingCategory
    case overallocatedEnvelope
    case rolloverRequiresReview
    case allocationMismatch
}

/// Decompose affected envelopes into disjoint general allocations, move the
/// source allocation, then rebuild enclosing caps. This preserves totals even
/// across different capped branches or through intermediate capped ancestors.
public enum BudgetMergePlanner {
    private struct Scope: Hashable {
        let month: BudgetMonth
        let currency: CurrencyCode
    }

    public static func merging(
        sourceID: UUID, targetID: UUID, nodes: [BudgetNode], currency: CurrencyCode
    ) throws -> [BudgetNode] {
        let ancestors = ancestorIDs(of: sourceID, nodes: nodes)
            .union(ancestorIDs(of: targetID, nodes: nodes))
        let result = try configuration(
            sourceID: sourceID, targetID: targetID, nodes: nodes, currency: currency,
            affectedIDs: ancestors
        )
        let related = relatedIDs(sourceID: sourceID, targetID: targetID, nodes: nodes).union(ancestors)
        return try applyingScopes(
            nodes: nodes, initial: result, affectedIDs: ancestors, relatedIDs: related
        ) { resolved, currency in
            try configuration(sourceID: sourceID, targetID: targetID, nodes: resolved,
                              currency: currency, affectedIDs: ancestors)
        }
    }

    private static func applyingScopes(
        nodes: [BudgetNode], initial: [BudgetNode], affectedIDs: Set<UUID>, relatedIDs: Set<UUID>,
        operation: ([BudgetNode], CurrencyCode) throws -> [BudgetNode]
    ) throws -> [BudgetNode] {
        var result = initial
        let allocations = nodes.filter { relatedIDs.contains($0.id) }.flatMap(\.monthlyAllocations)
        let scopeSet = Set<Scope>(allocations.map { Scope(month: $0.month, currency: $0.currency) })
        let scopes = scopeSet.sorted { left, right in
            if left.month == right.month { return left.currency < right.currency }
            return left.month < right.month
        }
        for scope in scopes {
            try Task.checkCancellation()
            let resolved = nodes.map { $0.resolved(for: scope.month, currency: scope.currency) }
            let scoped = try operation(resolved, scope.currency)
            let byID: [UUID: BudgetNode] = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })
            for index in result.indices where affectedIDs.contains(result[index].id) {
                guard let desired = byID[result[index].id] else { throw BudgetMergeError.missingCategory }
                let actual = result[index].resolved(for: scope.month, currency: scope.currency)
                if actual.limit != desired.limit || actual.allocationMode != desired.allocationMode
                    || actual.purpose != desired.purpose {
                    try result[index].setMonthlyAllocation(MonthlyBudgetAllocation(
                        month: scope.month, currency: scope.currency, limit: desired.limit,
                        mode: desired.allocationMode, purpose: desired.purpose
                    ))
                }
            }
        }
        return result
    }

    public static func moving(
        categoryID: UUID, parentID: UUID?, nodes: [BudgetNode], currency: CurrencyCode
    ) throws -> [BudgetNode] {
        var affected = ancestorIDs(of: categoryID, nodes: nodes)
        if let parentID { affected.formUnion(ancestorIDs(of: parentID, nodes: nodes)) }
        let initial = try moveConfiguration(
            categoryID: categoryID, parentID: parentID, nodes: nodes,
            currency: currency, affectedIDs: affected
        )
        let related = relatedIDs(sourceID: categoryID, targetID: categoryID, nodes: nodes).union(affected)
        return try applyingScopes(nodes: nodes, initial: initial, affectedIDs: affected, relatedIDs: related) {
            try moveConfiguration(categoryID: categoryID, parentID: parentID, nodes: $0,
                                  currency: $1, affectedIDs: affected)
        }
    }

    private static func moveConfiguration(
        categoryID: UUID, parentID: UUID?, nodes: [BudgetNode], currency: CurrencyCode,
        affectedIDs: Set<UUID>
    ) throws -> [BudgetNode] {
        let before = try BudgetTree(currency: currency, nodes: nodes)
        guard let category = nodes.first(where: { $0.id == categoryID }) else {
            throw BudgetMergeError.missingCategory
        }
        let hierarchy = nodes.map { original -> BudgetNode in
            var node = original
            if node.id == categoryID { node.parentID = parentID }
            return node
        }
        _ = try BudgetTree(currency: currency, nodes: hierarchy)
        let general = try generalAllocations(nodes: nodes, affectedIDs: affectedIDs, currency: currency)
        let result = try rebuilding(
            hierarchy: hierarchy, affectedIDs: affectedIDs, general: general,
            source: category, targetID: categoryID, combined: nil, currency: currency, isMerge: false
        )
        try validateRolloverScopes(before: nodes, after: result, affectedIDs: affectedIDs, movingID: categoryID)
        let after = try BudgetTree(currency: currency, nodes: result)
        guard try before.planSummary(directSpending: [:])?.limit
            == after.planSummary(directSpending: [:])?.limit else { throw BudgetMergeError.allocationMismatch }
        return result
    }

    public static func mergedNode(
        sourceID: UUID, targetID: UUID, nodes: [BudgetNode], currency: CurrencyCode
    ) throws -> BudgetNode {
        guard let result = try merging(sourceID: sourceID, targetID: targetID, nodes: nodes, currency: currency)
            .first(where: { $0.id == targetID }) else { throw BudgetMergeError.missingCategory }
        return result
    }

    private static func configuration(
        sourceID: UUID, targetID: UUID, nodes: [BudgetNode], currency: CurrencyCode,
        affectedIDs: Set<UUID>
    ) throws -> [BudgetNode] {
        let tree = try BudgetTree(currency: currency, nodes: nodes)
        guard sourceID != targetID, let source = nodes.first(where: { $0.id == sourceID }),
              let target = nodes.first(where: { $0.id == targetID }) else { throw BudgetMergeError.missingCategory }
        let general = try generalAllocations(nodes: nodes, affectedIDs: affectedIDs, currency: currency)
        let hierarchy = reparented(source: source, target: target, nodes: nodes)
        let combined: Money?
        if general[sourceID] != nil || general[targetID] != nil {
            combined = try (general[sourceID] ?? .zero(currency: currency)).adding(general[targetID] ?? .zero(currency: currency))
        } else { combined = nil }
        let result = try rebuilding(
            hierarchy: hierarchy, affectedIDs: affectedIDs, general: general,
            source: source, targetID: targetID, combined: combined, currency: currency
        )
        try validateRolloverScopes(
            before: nodes, after: result, affectedIDs: affectedIDs,
            sourceID: sourceID, targetID: targetID
        )
        let after = try BudgetTree(currency: currency, nodes: result)
        let beforeLimit = try tree.planSummary(directSpending: [:])?.limit ?? .zero(currency: currency)
        let afterLimit = try after.planSummary(directSpending: [:])?.limit ?? .zero(currency: currency)
        guard beforeLimit == afterLimit else { throw BudgetMergeError.allocationMismatch }
        return result
    }

    private static func generalAllocations(
        nodes: [BudgetNode], affectedIDs: Set<UUID>, currency: CurrencyCode
    ) throws -> [UUID: Money] {
        let totals = try BudgetAggregation(currency: currency, nodes: nodes, effectiveLimits: [:])
        var result: [UUID: Money] = [:]
        for node in nodes where affectedIDs.contains(node.id) {
            guard let limit = node.limit else { continue }
            if node.allocationMode == .fixedTotal {
                let general = try limit.subtracting(totals.childrenTotals[node.id] ?? .zero(currency: currency))
                guard general.amount >= .zero else { throw BudgetMergeError.overallocatedEnvelope }
                result[node.id] = general
            } else { result[node.id] = limit }
        }
        return result
    }

    private static func rebuilding(
        hierarchy: [BudgetNode], affectedIDs: Set<UUID>, general: [UUID: Money],
        source: BudgetNode, targetID: UUID, combined: Money?, currency: CurrencyCode, isMerge: Bool = true
    ) throws -> [BudgetNode] {
        var updated: [UUID: BudgetNode] = [:]
        var childTotals: [UUID: Money] = [:]
        for item in BudgetOutline.items(hierarchy).reversed() {
            var node = item.node
            if isMerge, node.id == targetID {
                node.limit = combined
                node.allocationMode = .automatic
                if node.purpose == .unclassified { node.purpose = source.purpose }
                if node.rolloverRule == .none {
                    node.rolloverRule = source.rolloverRule
                    node.rolloverStartedAt = source.rolloverStartedAt
                }
            } else if affectedIDs.contains(node.id), node.allocationMode == .fixedTotal,
                      let own = general[node.id] {
                node.limit = try own.adding(childTotals[node.id] ?? .zero(currency: currency))
            }
            var total = node.limit
            if node.allocationMode == .automatic || node.limit == nil, let children = childTotals[node.id] {
                total = try (total ?? .zero(currency: currency)).adding(children)
            }
            if let parent = node.parentID, let total {
                childTotals[parent] = try (childTotals[parent] ?? .zero(currency: currency)).adding(total)
            }
            updated[node.id] = node
        }
        return try hierarchy.map {
            guard let node = updated[$0.id] else { throw BudgetMergeError.missingCategory }
            return node
        }
    }

    public static func validateRolloverScopes(
        before: [BudgetNode], after: [BudgetNode], affectedIDs: Set<UUID>,
        sourceID: UUID? = nil, targetID: UUID? = nil, movingID: UUID? = nil
    ) throws {
        let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard beforeByID.count == before.count, afterByID.count == after.count else {
            throw BudgetMergeError.allocationMismatch
        }
        let oldRolling = descendantRolloverCounts(nodes: before)
        let newRolling = descendantRolloverCounts(nodes: after)
        guard !oldRolling.isEmpty || !newRolling.isEmpty else { return }
        let oldMembership: Set<UUID>
        let newMembership: Set<UUID>
        if let sourceID, let targetID {
            oldMembership = ancestorIDs(of: sourceID, nodes: before)
            newMembership = ancestorIDs(of: targetID, nodes: before)
        } else if let movingID {
            oldMembership = ancestorIDs(of: movingID, nodes: before)
            newMembership = ancestorIDs(of: movingID, nodes: after)
        } else {
            guard beforeByID.mapValues(\.parentID) == afterByID.mapValues(\.parentID) else {
                throw BudgetMergeError.allocationMismatch
            }
            oldMembership = []
            newMembership = []
        }
        for id in affectedIDs {
            let old = beforeByID[id], new = afterByID[id]
            let wasCap = old?.allocationMode == .fixedTotal && old?.limit != nil
            let isCap = new?.allocationMode == .fixedTotal && new?.limit != nil
            let overlaps = (wasCap && oldRolling[id, default: 0] > 0)
                || (isCap && newRolling[id, default: 0] > 0)
            guard overlaps else { continue }
            guard wasCap, isCap, old?.limit == new?.limit,
                  oldMembership.contains(id) == newMembership.contains(id) else {
                throw BudgetMergeError.rolloverRequiresReview
            }
        }
    }

    private static func descendantRolloverCounts(nodes: [BudgetNode]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in BudgetOutline.items(nodes).reversed() {
            let ownsCarry = item.node.limit != nil && item.node.rolloverRule != .none
            let subtreeCount = counts[item.id, default: 0] + (ownsCarry ? 1 : 0)
            if subtreeCount > 0, let parent = item.node.parentID {
                counts[parent, default: 0] += subtreeCount
            }
        }
        return counts
    }

    private static func reparented(source: BudgetNode, target: BudgetNode, nodes: [BudgetNode]) -> [BudgetNode] {
        let targetWasDescendant = ancestorIDs(of: target.id, nodes: nodes).contains(source.id)
        return nodes.filter { $0.id != source.id }.map { value in
            var node = value
            if node.id == target.id, targetWasDescendant { node.parentID = source.parentID }
            else if node.parentID == source.id { node.parentID = target.id }
            return node
        }
    }

    private static func ancestorIDs(of id: UUID, nodes: [BudgetNode]) -> Set<UUID> {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Set<UUID>()
        var next: UUID? = id
        while let id = next, result.insert(id).inserted { next = byID[id]?.parentID }
        return result
    }

    private static func relatedIDs(sourceID: UUID, targetID: UUID, nodes: [BudgetNode]) -> Set<UUID> {
        let children = Dictionary(grouping: nodes, by: \.parentID)
        var result = Set<UUID>()
        var pending = [sourceID, targetID]
        while let id = pending.popLast() {
            guard result.insert(id).inserted else { continue }
            pending.append(contentsOf: (children[id] ?? []).map(\.id))
        }
        return result
    }
}
