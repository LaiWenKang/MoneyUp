import Foundation

/// The job a budget allocation performs in the user's monthly plan.
///
/// Existing records decode as `unclassified`. This is intentionally
/// conservative: an upgrade must never guess that rent, debt, or savings are
/// discretionary money merely because their category names look familiar.
public enum BudgetPurpose: String, Codable, CaseIterable, Hashable, Sendable {
    case unclassified
    case flexible
    case commitment
    case debt
    case goal
}

/// Determines what may enter the following month's allocation.
///
/// Existing budgets decode as `none`; enabling rollover therefore starts from
/// an explicit activation month and never rewrites prior months by surprise.
public enum BudgetRolloverRule: String, Codable, CaseIterable, Hashable, Sendable {
    /// Every Gregorian reporting month starts with the configured limit.
    case none
    /// Only an unused positive balance is carried. Overspending never reduces
    /// the next month's configured allocation.
    case positiveOnly
    /// The complete signed balance is carried. Overspending therefore reduces
    /// the next month's effective allocation.
    case fullBalance
}

public struct BudgetNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var parentID: UUID?
    public var name: String
    public var limit: Money?
    public var purpose: BudgetPurpose
    public var rolloverRule: BudgetRolloverRule
    /// The instant at which rollover was explicitly enabled. The reporting
    /// calendar aligns it to a month; earlier history is never backfilled.
    public var rolloverStartedAt: Date?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        limit: Money? = nil,
        purpose: BudgetPurpose = .unclassified,
        rolloverRule: BudgetRolloverRule = .none,
        rolloverStartedAt: Date? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.limit = limit
        self.purpose = purpose
        self.rolloverRule = rolloverRule
        self.rolloverStartedAt = rolloverRule == .none ? nil : rolloverStartedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentID
        case name
        case limit
        case purpose
        case rolloverRule
        case rolloverStartedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        name = try container.decode(String.self, forKey: .name)
        limit = try container.decodeIfPresent(Money.self, forKey: .limit)
        purpose = try container.decodeIfPresent(
            BudgetPurpose.self,
            forKey: .purpose
        ) ?? .unclassified
        rolloverRule = try container.decodeIfPresent(
            BudgetRolloverRule.self,
            forKey: .rolloverRule
        ) ?? .none
        rolloverStartedAt = rolloverRule == .none
            ? nil
            : try container.decodeIfPresent(Date.self, forKey: .rolloverStartedAt)
    }
}

public struct BudgetProgress: Equatable, Sendable {
    public let node: BudgetNode
    /// The configured limit plus carry entering this period.
    public let effectiveLimit: Money?
    public let spent: Money
    public let remaining: Money?

    public init(
        node: BudgetNode,
        effectiveLimit: Money?,
        spent: Money,
        remaining: Money?
    ) {
        self.node = node
        self.effectiveLimit = effectiveLimit
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
                totals[id] = try CheckedDecimal.adding(
                    totals[id] ?? .zero,
                    money.amount
                )
                currentID = nodesByID[id]?.parentID
            }
        }

        return try totals.reduce(into: [:]) { result, item in
            result[item.key] = try Money(item.value, currency: currency)
        }
    }

    public func progress(
        directSpending: [UUID: Money],
        effectiveLimits: [UUID: Money] = [:]
    ) throws -> [BudgetProgress] {
        let totals = try rolledUpSpending(directSpending: directSpending)

        try validate(effectiveLimits: effectiveLimits)

        return try nodes.map { node in
            let spent = totals[node.id] ?? Money.zero(currency: currency)
            let limit = effectiveLimits[node.id] ?? node.limit
            let remaining = try limit?.subtracting(spent)
            return BudgetProgress(
                node: node,
                effectiveLimit: limit,
                spent: spent,
                remaining: remaining
            )
        }
    }

    public func planSummary(
        directSpending: [UUID: Money],
        effectiveLimits: [UUID: Money] = [:]
    ) throws -> BudgetPlanSummary? {
        try planSummary(
            directSpending: directSpending,
            topmostLimits: topmostLimitedNodes,
            effectiveLimits: effectiveLimits
        )
    }

    /// Produces a non-overlapping plan summary for one purpose only.
    ///
    /// A topmost limited node owns the allocation beneath it. This prevents a
    /// child marked as rent from being subtracted once as a commitment and
    /// counted again inside a flexible parent cap. To split purposes, users
    /// place limits on separate sibling allocations instead of one mixed cap.
    public func planSummary(
        directSpending: [UUID: Money],
        purpose: BudgetPurpose,
        effectiveLimits: [UUID: Money] = [:]
    ) throws -> BudgetPlanSummary? {
        let selected = topmostLimitedNodes.filter {
            effectivePurpose(for: $0.id) == purpose
        }
        return try planSummary(
            directSpending: directSpending,
            topmostLimits: selected,
            effectiveLimits: effectiveLimits
        )
    }

    /// Topmost allocations whose purpose was not explicitly configured.
    public var limitedNodesNeedingPurpose: [BudgetNode] {
        topmostLimitedNodes.filter {
            effectivePurpose(for: $0.id) == .unclassified
        }
    }

    /// Every category governed by the requested allocation purpose.
    /// Scheduled expenses use this set so reserved bills and debt are never
    /// deducted from (or presented as part of) flexible spending.
    public func categoryIDs(governedBy purpose: BudgetPurpose) -> Set<UUID> {
        Set(nodes.compactMap { node in
            guard let owner = topmostLimitedOwner(for: node.id),
                  effectivePurpose(for: owner.id) == purpose else {
                return nil
            }
            return node.id
        })
    }

    public func effectivePurpose(for nodeID: UUID) -> BudgetPurpose {
        var currentID: UUID? = nodeID
        while let id = currentID, let node = nodesByID[id] {
            if node.purpose != .unclassified { return node.purpose }
            currentID = node.parentID
        }
        return .unclassified
    }

    private var topmostLimitedNodes: [BudgetNode] {
        nodes.filter { node in
            guard node.limit != nil else { return false }
            var parentID = node.parentID
            while let id = parentID, let parent = nodesByID[id] {
                if parent.limit != nil { return false }
                parentID = parent.parentID
            }
            return true
        }
    }

    private func topmostLimitedOwner(for nodeID: UUID) -> BudgetNode? {
        var owner: BudgetNode?
        var currentID: UUID? = nodeID
        while let id = currentID, let node = nodesByID[id] {
            if node.limit != nil { owner = node }
            currentID = node.parentID
        }
        return owner
    }

    private func planSummary(
        directSpending: [UUID: Money],
        topmostLimits: [BudgetNode],
        effectiveLimits: [UUID: Money]
    ) throws -> BudgetPlanSummary? {
        let progress = try progress(
            directSpending: directSpending,
            effectiveLimits: effectiveLimits
        )
        let progressByID = Dictionary(
            uniqueKeysWithValues: progress.map { ($0.node.id, $0) }
        )
        guard !topmostLimits.isEmpty else { return nil }

        var limit = Decimal.zero
        for money in topmostLimits.compactMap({ effectiveLimits[$0.id] ?? $0.limit }) {
            limit = try CheckedDecimal.adding(limit, money.amount)
        }
        var spent = Decimal.zero
        for node in topmostLimits {
            spent = try CheckedDecimal.adding(
                spent,
                progressByID[node.id]?.spent.amount ?? .zero
            )
        }
        var totalSpent = Decimal.zero
        for node in nodes where node.parentID == nil {
            totalSpent = try CheckedDecimal.adding(
                totalSpent,
                progressByID[node.id]?.spent.amount ?? .zero
            )
        }

        return BudgetPlanSummary(
            limit: try Money(limit, currency: currency),
            spent: try Money(spent, currency: currency),
            remaining: try Money(
                CheckedDecimal.subtracting(limit, spent),
                currency: currency
            ),
            unbudgetedSpent: try Money(
                CheckedDecimal.subtracting(totalSpent, spent),
                currency: currency
            )
        )
    }

    private func validate(effectiveLimits: [UUID: Money]) throws {
        for (nodeID, limit) in effectiveLimits {
            guard nodesByID[nodeID] != nil else {
                throw BudgetTreeError.unknownSpendingNode(nodeID)
            }
            guard limit.currency == currency else {
                throw BudgetTreeError.limitCurrencyMismatch(
                    nodeID: nodeID,
                    expected: currency,
                    actual: limit.currency
                )
            }
        }
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
