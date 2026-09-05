import Foundation

/// Resolves one validated currency/period tree without persisting derived totals.
/// Iterative postorder keeps arbitrarily deep category trees off the call stack.
struct BudgetAggregation {
    let totals: [UUID: Money]
    let childrenTotals: [UUID: Money]
    let summaryNodes: [BudgetNode]

    init(
        currency: CurrencyCode,
        nodes: [BudgetNode],
        effectiveLimits: [UUID: Money]
    ) throws {
        let children = Dictionary(grouping: nodes, by: \.parentID)
        var totals: [UUID: Money] = [:]
        var childrenTotals: [UUID: Money] = [:]
        var stack = (children[nil] ?? []).map { ($0, false) }
        while let (node, visited) = stack.popLast() {
            if !visited {
                stack.append((node, true))
                stack.append(contentsOf: (children[node.id] ?? []).map { ($0, false) })
                continue
            }
            var childTotal: Money?
            for child in children[node.id] ?? [] {
                guard let amount = totals[child.id] else { continue }
                childTotal = try (childTotal ?? .zero(currency: currency)).adding(amount)
            }
            childrenTotals[node.id] = childTotal
            let own = effectiveLimits[node.id] ?? node.limit
            if node.allocationMode == .fixedTotal, let own {
                totals[node.id] = own
            } else if let childTotal {
                totals[node.id] = try (own ?? .zero(currency: currency)).adding(childTotal)
            } else {
                totals[node.id] = own
            }
        }
        self.totals = totals
        self.childrenTotals = childrenTotals
        // Legacy uncapped groups retain their original spending coverage. New
        // automatic groups own their complete subtree, including direct logs.
        var frontier = children[nil] ?? []
        var summaryNodes: [BudgetNode] = []
        while let node = frontier.popLast() {
            if totals[node.id] != nil,
               node.allocationMode == .automatic || node.limit != nil {
                summaryNodes.append(node)
            } else {
                frontier.append(contentsOf: children[node.id] ?? [])
            }
        }
        self.summaryNodes = summaryNodes
    }
}
