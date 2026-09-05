import Foundation
import MoneyUpCore
import XCTest

final class BudgetMergeConservationTests: XCTestCase {
    func testEveryMergeDirectionConservesMixedHierarchyAllocations() throws {
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        let month = try BudgetMonth(year: 2026, month: 9)
        for seed in 1...6 {
            var nodes = try fixture(seed: seed, currency: sgd)
            try nodes[seed].setMonthlyAllocation(MonthlyBudgetAllocation(
                month: month, currency: usd, limit: Money(25, currency: usd), mode: .automatic
            ))
            let original = try BudgetTree(currency: sgd, nodes: nodes)
            // Fixture caps are built from known disjoint general allocations.
            XCTAssertEqual(try original.planSummary(directSpending: [:])?.limit.amount, 275)
            for source in nodes {
                for target in nodes where target.id != source.id {
                    let merged = try BudgetMergePlanner.merging(
                        sourceID: source.id, targetID: target.id, nodes: nodes, currency: sgd
                    )
                    let after = try BudgetTree(currency: sgd, nodes: merged)
                    XCTAssertEqual(try after.planSummary(directSpending: [:])?.limit.amount, 275, "Seed \(seed), \(source.name) into \(target.name)")
                    let foreign = try BudgetTree(currency: usd, nodes: merged, month: month)
                    XCTAssertEqual(try foreign.planSummary(directSpending: [:])?.limit.amount, 25)
                    XCTAssertEqual(merged.count, nodes.count - 1)
                    XCTAssertFalse(merged.contains { $0.id == source.id })
                }
                let parentByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parentID) })
                for parentID in [UUID?.none] + nodes.map({ Optional($0.id) }) {
                    var cursor = parentID
                    var createsCycle = false
                    while let id = cursor {
                        if id == source.id { createsCycle = true; break }
                        cursor = parentByID[id] ?? nil
                    }
                    if createsCycle { continue }
                    let moved = try BudgetMergePlanner.moving(categoryID: source.id, parentID: parentID, nodes: nodes, currency: sgd)
                    XCTAssertEqual(try BudgetTree(currency: sgd, nodes: moved).planSummary(directSpending: [:])?.limit.amount, 275)
                    XCTAssertEqual(try BudgetTree(currency: usd, nodes: moved, month: month).planSummary(directSpending: [:])?.limit.amount, 25)
                }
            }
        }
    }

    private func fixture(seed: Int, currency: CurrencyCode) throws -> [BudgetNode] {
        var nodes: [BudgetNode] = []
        for index in 0..<10 {
            let parent = index < 2 ? nil : nodes[(seed * 7 + index * 3) % index].id
            nodes.append(BudgetNode(
                parentID: parent, name: "Category \(index)",
                limit: try Money(Decimal((index + 1) * 5), currency: currency),
                allocationMode: (seed + index).isMultiple(of: 2) ? .fixedTotal : .automatic
            ))
        }
        var childTotals: [UUID: Money] = [:]
        var resolved: [UUID: BudgetNode] = [:]
        for item in BudgetOutline.items(nodes).reversed() {
            var node = item.node
            let own = try XCTUnwrap(node.limit)
            let total = try own.adding(childTotals[node.id] ?? .zero(currency: currency))
            if node.allocationMode == .fixedTotal { node.limit = total }
            if let parent = node.parentID {
                childTotals[parent] = try (childTotals[parent] ?? .zero(currency: currency)).adding(total)
            }
            resolved[node.id] = node
        }
        return try nodes.map { try XCTUnwrap(resolved[$0.id]) }
    }
}
