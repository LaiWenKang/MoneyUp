import Foundation

public struct BudgetOutlineItem: Identifiable, Equatable, Sendable {
    public let node: BudgetNode
    public let depth: Int
    public let rootID: UUID
    public var id: UUID { node.id }
}

public enum BudgetOutline {
    public static func items(_ nodes: [BudgetNode]) -> [BudgetOutlineItem] {
        let children = Dictionary(grouping: nodes, by: \.parentID).mapValues { values in
            values.sorted {
                $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
            }
        }
        var pending = (children[nil] ?? []).reversed().map { ($0, 0, $0.id) }
        var visited = Set<UUID>()
        var result: [BudgetOutlineItem] = []
        while let (node, depth, rootID) = pending.popLast() {
            guard visited.insert(node.id).inserted else { continue }
            result.append(BudgetOutlineItem(node: node, depth: depth, rootID: rootID))
            pending.append(contentsOf: (children[node.id] ?? []).reversed().map {
                ($0, depth + 1, rootID)
            })
        }
        return result
    }
}
