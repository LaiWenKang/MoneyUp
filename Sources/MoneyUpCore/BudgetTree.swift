import Foundation

public struct BudgetNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var parentID: UUID?
    public var name: String
    public var limit: Money?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        limit: Money? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.limit = limit
    }
}

public struct BudgetProgress: Equatable, Sendable {
    public let node: BudgetNode
    public let spent: Money
    public let remaining: Money?

    public init(node: BudgetNode, spent: Money, remaining: Money?) {
        self.node = node
        self.spent = spent
        self.remaining = remaining
    }
}

/// A non-overlapping summary of the configured monthly plan.
///
/// A limited node is counted only when none of its ancestors has a limit. This
/// supports a budget set directly on a child category while preventing a child
/// allocation from being added again beneath a capped parent.
public struct BudgetPlanSummary: Equatable, Sendable {
    public let limit: Money
    public let spent: Money
    public let remaining: Money
    public let unbudgetedSpent: Money

    public init(
        limit: Money,
        spent: Money,
        remaining: Money,
        unbudgetedSpent: Money
    ) {
        self.limit = limit
        self.spent = spent
        self.remaining = remaining
        self.unbudgetedSpent = unbudgetedSpent
    }
}

public enum BudgetTreeError: Error, Equatable {
    case duplicateNode(UUID)
    case missingParent(nodeID: UUID, parentID: UUID)
    case cycle(nodeID: UUID)
    case negativeLimit(nodeID: UUID)
    case limitCurrencyMismatch(
        nodeID: UUID,
        expected: CurrencyCode,
        actual: CurrencyCode
    )
    case unknownSpendingNode(UUID)
    case spendingCurrencyMismatch(
        nodeID: UUID,
        expected: CurrencyCode,
        actual: CurrencyCode
    )
}

/// A validated hierarchy for budget groups, categories, and subcategories.
///
/// Limits belong to individual nodes. A parent limit is a cap over all
/// descendant spending; child limits are allocations within it and are never
/// added to the parent's limit.
public struct BudgetTree: Codable, Equatable, Sendable {
    public let currency: CurrencyCode
    public let nodes: [BudgetNode]

    private let nodesByID: [UUID: BudgetNode]

    public init(currency: CurrencyCode, nodes: [BudgetNode]) throws {
        var index: [UUID: BudgetNode] = [:]

        for node in nodes {
            guard index.updateValue(node, forKey: node.id) == nil else {
                throw BudgetTreeError.duplicateNode(node.id)
            }

            if let limit = node.limit, limit.currency != currency {
                throw BudgetTreeError.limitCurrencyMismatch(
                    nodeID: node.id,
                    expected: currency,
                    actual: limit.currency
                )
            }
            if let limit = node.limit, limit.amount < .zero {
                throw BudgetTreeError.negativeLimit(nodeID: node.id)
            }
        }

        for node in nodes {
            if let parentID = node.parentID, index[parentID] == nil {
                throw BudgetTreeError.missingParent(
                    nodeID: node.id,
                    parentID: parentID
                )
            }
        }

        try Self.validateAcyclic(nodes: nodes, index: index)

        self.currency = currency
        self.nodes = nodes
        nodesByID = index
    }

    /// Rolls spending recorded directly against a node into that node and all
    /// of its ancestors. Negative values are permitted for refunds.
    public func rolledUpSpending(
        directSpending: [UUID: Money]
    ) throws -> [UUID: Money] {
        var totals = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, Decimal.zero) }
        )

        for (nodeID, money) in directSpending {
            guard nodesByID[nodeID] != nil else {
                throw BudgetTreeError.unknownSpendingNode(nodeID)
            }
            guard money.currency == currency else {
                throw BudgetTreeError.spendingCurrencyMismatch(
                    nodeID: nodeID,
                    expected: currency,
                    actual: money.currency
                )
            }

            var currentID: UUID? = nodeID
            while let id = currentID {
                totals[id, default: .zero] += money.amount
                currentID = nodesByID[id]?.parentID
            }
        }

        return try totals.reduce(into: [:]) { result, item in
            result[item.key] = try Money(item.value, currency: currency)
        }
    }

    public func progress(
        directSpending: [UUID: Money]
    ) throws -> [BudgetProgress] {
        let totals = try rolledUpSpending(directSpending: directSpending)

        return try nodes.map { node in
            let spent = totals[node.id] ?? Money.zero(currency: currency)
            let remaining = try node.limit?.subtracting(spent)
            return BudgetProgress(
                node: node,
                spent: spent,
                remaining: remaining
            )
        }
    }

    public func planSummary(
        directSpending: [UUID: Money]
    ) throws -> BudgetPlanSummary? {
        let progress = try progress(directSpending: directSpending)
        let progressByID = Dictionary(
            uniqueKeysWithValues: progress.map { ($0.node.id, $0) }
        )
        let topmostLimits = nodes.filter { node in
            guard node.limit != nil else { return false }
            var parentID = node.parentID
            while let id = parentID, let parent = nodesByID[id] {
                if parent.limit != nil { return false }
                parentID = parent.parentID
            }
            return true
        }
        guard !topmostLimits.isEmpty else { return nil }

        let limit = topmostLimits
            .compactMap(\.limit)
            .reduce(Decimal.zero) { $0 + $1.amount }
        let spent = topmostLimits.reduce(Decimal.zero) {
            $0 + (progressByID[$1.id]?.spent.amount ?? .zero)
        }
        let totalSpent = nodes
            .filter { $0.parentID == nil }
            .reduce(Decimal.zero) {
                $0 + (progressByID[$1.id]?.spent.amount ?? .zero)
            }

        return BudgetPlanSummary(
            limit: try Money(limit, currency: currency),
            spent: try Money(spent, currency: currency),
            remaining: try Money(limit - spent, currency: currency),
            unbudgetedSpent: try Money(totalSpent - spent, currency: currency)
        )
    }

    private static func validateAcyclic(
        nodes: [BudgetNode],
        index: [UUID: BudgetNode]
    ) throws {
        for node in nodes {
            var visited = Set<UUID>()
            var currentID: UUID? = node.id

            while let id = currentID {
                guard visited.insert(id).inserted else {
                    throw BudgetTreeError.cycle(nodeID: id)
                }
                currentID = index[id]?.parentID
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case currency
        case nodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currency = try container.decode(CurrencyCode.self, forKey: .currency)
        let nodes = try container.decode([BudgetNode].self, forKey: .nodes)

        do {
            try self.init(currency: currency, nodes: nodes)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .nodes,
                in: container,
                debugDescription: "Decoded budget hierarchy is invalid: \(error)"
            )
        }
    }
}
