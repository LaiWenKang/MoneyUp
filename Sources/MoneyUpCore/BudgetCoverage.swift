import Foundation

/// Ownership and classification of direct postings, independent of display
/// totals. A fixed envelope owns its descendants; automatic groups retain
/// each allocation's purpose and also account for direct, unallocated logs.
struct BudgetCoverage {
    let contributors: [BudgetNode]
    let coveredIDs: Set<UUID>
    let purposeByID: [UUID: BudgetPurpose]
    let ownerByID: [UUID: UUID]

    init(nodes: [BudgetNode]) {
        let outline = BudgetOutline.items(nodes)
        var hasBudget = Set<UUID>()
        for item in outline.reversed() {
            if item.node.limit != nil { hasBudget.insert(item.id) }
            if hasBudget.contains(item.id), let parent = item.node.parentID { hasBudget.insert(parent) }
        }
        var covered = Set<UUID>()
        var declared: [UUID: BudgetPurpose] = [:]
        var purposes: [UUID: BudgetPurpose] = [:]
        var owners: [UUID: UUID] = [:]
        var nearestAllocation: [UUID: UUID] = [:]
        var governingOwners: [UUID: UUID] = [:]
        var contributors: [BudgetNode] = []
        for item in outline {
            let node = item.node
            let parentPurpose = node.parentID.flatMap { declared[$0] } ?? .unclassified
            declared[node.id] = node.purpose == .unclassified ? parentPurpose : node.purpose
            let parentOwner = node.parentID.flatMap { owners[$0] }
            let owner = parentOwner ?? (node.limit != nil && node.allocationMode == .fixedTotal ? node.id : nil)
            owners[node.id] = owner
            nearestAllocation[node.id] = node.limit != nil ? node.id
                : node.parentID.flatMap { nearestAllocation[$0] }
            let governingOwner = owner ?? nearestAllocation[node.id]
            governingOwners[node.id] = governingOwner
            if node.limit != nil, parentOwner == nil { contributors.append(node) }
            if node.parentID.map({ covered.contains($0) }) == true
                || node.limit != nil || (node.allocationMode == .automatic && hasBudget.contains(node.id)) {
                covered.insert(node.id)
            }
            purposes[node.id] = governingOwner.flatMap { declared[$0] } ?? declared[node.id]
        }
        self.contributors = contributors
        coveredIDs = covered
        purposeByID = purposes
        ownerByID = governingOwners
    }
}

enum BudgetAllocationSpending {
    /// General allocations also cover unallocated descendants. A descendant
    /// with its own limit starts a separate allocation, even inside a cap.
    static func totals(
        nodes: [BudgetNode], currency: CurrencyCode, directSpending: [UUID: Money]
    ) throws -> [UUID: Money] {
        var owners: [UUID: UUID] = [:]
        var result: [UUID: Money] = [:]
        for item in BudgetOutline.items(nodes) {
            let owner = item.node.limit != nil ? item.id
                : item.node.parentID.flatMap { owners[$0] }
            owners[item.id] = owner
            if let owner, let amount = directSpending[item.id] {
                result[owner] = try (result[owner] ?? .zero(currency: currency)).adding(amount)
            }
        }
        return result
    }
}
