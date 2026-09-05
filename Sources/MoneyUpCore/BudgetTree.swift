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

public enum BudgetAllocationMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// A legacy envelope containing its descendants, preserved on upgrade.
    case fixedTotal
    /// A direct allocation, added to the independently budgeted children.
    case automatic
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
    public var allocationMode: BudgetAllocationMode
    public var monthlyAllocations: [MonthlyBudgetAllocation]
    public var purpose: BudgetPurpose
    /// Optional daily/weekly guidance derived from the monthly source of truth.
    public var pacingCadence: BudgetPacingCadence
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
        pacingCadence: BudgetPacingCadence = .monthly,
        rolloverRule: BudgetRolloverRule = .none,
        rolloverStartedAt: Date? = nil,
        allocationMode: BudgetAllocationMode = .fixedTotal,
        monthlyAllocations: [MonthlyBudgetAllocation] = []
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.limit = limit
        self.allocationMode = allocationMode
        self.monthlyAllocations = monthlyAllocations
        self.purpose = purpose
        self.pacingCadence = pacingCadence
        self.rolloverRule = rolloverRule
        self.rolloverStartedAt = rolloverRule == .none ? nil : rolloverStartedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentID
        case name
        case limit
        case allocationMode
        case monthlyAllocations
        case purpose
        case pacingCadence
        case rolloverRule
        case rolloverStartedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        name = try container.decode(String.self, forKey: .name)
        limit = try container.decodeIfPresent(Money.self, forKey: .limit)
        allocationMode = try container.decodeIfPresent(
            BudgetAllocationMode.self, forKey: .allocationMode
        ) ?? .fixedTotal
        monthlyAllocations = try container.decodeIfPresent(
            [MonthlyBudgetAllocation].self, forKey: .monthlyAllocations
        ) ?? []
        purpose = try container.decodeIfPresent(
            BudgetPurpose.self,
            forKey: .purpose
        ) ?? .unclassified
        pacingCadence = try container.decodeIfPresent(
            BudgetPacingCadence.self,
            forKey: .pacingCadence
        ) ?? .monthly
        rolloverRule = try container.decodeIfPresent(
            BudgetRolloverRule.self,
            forKey: .rolloverRule
        ) ?? .none
        rolloverStartedAt = rolloverRule == .none
            ? nil
            : try container.decodeIfPresent(Date.self, forKey: .rolloverStartedAt)
        try validateMonthlyAllocations()
    }
}

public struct BudgetProgress: Equatable, Sendable {
    public let node: BudgetNode
    /// The configured limit plus carry entering this period.
    public let effectiveLimit: Money?
    public let spent: Money
    public let remaining: Money?
    public let directSpent: Money
    public let directRemaining: Money?
    public let childAllocation: Money?

    public init(
        node: BudgetNode,
        effectiveLimit: Money?,
        spent: Money,
        remaining: Money?,
        directSpent: Money? = nil,
        directRemaining: Money? = nil,
        childAllocation: Money? = nil
    ) {
        self.node = node
        self.effectiveLimit = effectiveLimit
        self.spent = spent
        self.remaining = remaining
        self.directSpent = directSpent ?? spent
        self.directRemaining = directRemaining
        self.childAllocation = childAllocation
    }
}

/// A non-overlapping summary of the configured monthly plan.
///
/// Automatic groups add their general allocation and child allocations once.
/// Fixed envelopes contain their descendants; an enclosed child allocation is
/// never added a second time to that envelope.
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
/// Fixed limits cap all descendant spending. Automatic limits describe the
/// general allocation in addition to child allocations. Derived group totals
/// are calculated from the tree and are never persisted as extra allocations.
public struct BudgetTree: Codable, Equatable, Sendable {
    public let currency: CurrencyCode
    public let nodes: [BudgetNode]

    private let nodesByID: [UUID: BudgetNode]

    public init(
        currency: CurrencyCode,
        nodes sourceNodes: [BudgetNode],
        month: BudgetMonth? = nil
    ) throws {
        let nodes = month.map { month in
            sourceNodes.map { $0.resolved(for: month, currency: currency) }
        } ?? sourceNodes
        var index: [UUID: BudgetNode] = [:]

        for node in nodes {
            try node.validateMonthlyAllocations()
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
        let allocationSpending = try BudgetAllocationSpending.totals(
            nodes: nodes, currency: currency, directSpending: directSpending
        )

        try validate(effectiveLimits: effectiveLimits)

        let configured = try BudgetAggregation(currency: currency, nodes: nodes, effectiveLimits: [:])
        let allocation = try BudgetAggregation(
            currency: currency, nodes: nodes, effectiveLimits: effectiveLimits
        )
        return try nodes.map { node in
            let spent = totals[node.id] ?? Money.zero(currency: currency)
            let direct = directSpending[node.id] ?? Money.zero(currency: currency)
            let limit = allocation.totals[node.id]
            let remaining = try limit?.subtracting(spent)
            return BudgetProgress(
                node: node,
                effectiveLimit: limit,
                spent: spent,
                remaining: remaining,
                directSpent: direct,
                directRemaining: node.allocationMode == .automatic
                    ? try (effectiveLimits[node.id] ?? node.limit)?.subtracting(
                        allocationSpending[node.id] ?? .zero(currency: currency))
                    : nil,
                childAllocation: configured.childrenTotals[node.id]
            )
        }
    }

    public func planSummary(
        directSpending: [UUID: Money],
        effectiveLimits: [UUID: Money] = [:]
    ) throws -> BudgetPlanSummary? {
        let allocation = try BudgetAggregation(
            currency: currency, nodes: nodes, effectiveLimits: effectiveLimits
        )
        return try planSummary(
            directSpending: directSpending,
            topmostLimits: allocation.summaryNodes,
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
        _ = try rolledUpSpending(directSpending: directSpending)
        try validate(effectiveLimits: effectiveLimits)
        let coverage = BudgetCoverage(nodes: nodes)
        let selected = coverage.contributors.filter { coverage.purposeByID[$0.id] == purpose }
        guard !selected.isEmpty else { return nil }
        var limit = Money.zero(currency: currency)
        for node in selected {
            if let amount = effectiveLimits[node.id] ?? node.limit { limit = try limit.adding(amount) }
        }
        var spent = Money.zero(currency: currency)
        var totalSpent = Money.zero(currency: currency)
        for (id, amount) in directSpending {
            totalSpent = try totalSpent.adding(amount)
            if coverage.coveredIDs.contains(id), coverage.purposeByID[id] == purpose {
                spent = try spent.adding(amount)
            }
        }
        return try BudgetPlanSummary(
            limit: limit, spent: spent, remaining: limit.subtracting(spent),
            unbudgetedSpent: totalSpent.subtracting(spent)
        )
    }

    /// Topmost allocations whose purpose was not explicitly configured.
    public var limitedNodesNeedingPurpose: [BudgetNode] {
        let coverage = BudgetCoverage(nodes: nodes)
        return coverage.contributors.filter {
            coverage.purposeByID[$0.id] == .unclassified
        }
    }

    public func nodesNeedingPurpose(directSpending: [UUID: Money]) -> Set<UUID> {
        let coverage = BudgetCoverage(nodes: nodes)
        var result = Set(limitedNodesNeedingPurpose.map(\.id))
        for (id, amount) in directSpending where amount.amount > .zero
            && coverage.coveredIDs.contains(id) && coverage.purposeByID[id] == .unclassified {
            result.insert(coverage.ownerByID[id] ?? id)
        }
        return result
    }

    /// Every category governed by the requested allocation purpose.
    /// Scheduled expenses use this set so reserved bills and debt are never
    /// deducted from (or presented as part of) flexible spending.
    public func categoryIDs(governedBy purpose: BudgetPurpose) -> Set<UUID> {
        let coverage = BudgetCoverage(nodes: nodes)
        return Set(coverage.coveredIDs.filter { coverage.purposeByID[$0] == purpose })
    }

    public func effectivePurpose(for nodeID: UUID) -> BudgetPurpose {
        var currentID: UUID? = nodeID
        while let id = currentID, let node = nodesByID[id] {
            if node.purpose != .unclassified { return node.purpose }
            currentID = node.parentID
        }
        return .unclassified
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
        for node in topmostLimits {
            let money = progressByID[node.id]?.effectiveLimit
            guard let money else { continue }
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
        enum VisitState {
            case visiting
            case visited
        }

        // A missing state is white, `visiting` is gray, and `visited` is
        // black. Because every node has at most one parent, each node enters a
        // path once and is then permanently memoized. Keeping the traversal
        // iterative also avoids overflowing the stack for deeply nested
        // category trees.
        var states: [UUID: VisitState] = [:]
        states.reserveCapacity(nodes.count)

        for node in nodes {
            guard states[node.id] == nil else { continue }

            var path: [UUID] = []
            var currentID: UUID? = node.id

            while let id = currentID {
                switch states[id] {
                case .visiting:
                    throw BudgetTreeError.cycle(nodeID: id)
                case .visited:
                    currentID = nil
                case nil:
                    states[id] = .visiting
                    path.append(id)
                    currentID = index[id]?.parentID
                }
            }

            for id in path {
                states[id] = .visited
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
