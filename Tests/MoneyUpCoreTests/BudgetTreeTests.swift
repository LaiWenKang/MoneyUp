import Foundation
@testable import MoneyUpCore
import XCTest

final class BudgetTreeTests: XCTestCase {
    func testLegacyBudgetNodeDecodesAsUnclassified() throws {
        let sgd = try CurrencyCode("SGD")
        let original = BudgetNode(
            name: "Existing rent",
            limit: try Money(1_500, currency: sgd),
            purpose: .commitment
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "purpose")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BudgetNode.self, from: legacy)

        XCTAssertEqual(decoded.purpose, .unclassified)
        XCTAssertEqual(decoded.limit?.amount, 1_500)
    }

    func testFlexibleSummaryExcludesRentDebtAndGoals() throws {
        let sgd = try CurrencyCode("SGD")
        let flexibleID = UUID()
        let rentID = UUID()
        let debtID = UUID()
        let goalID = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [
                BudgetNode(
                    id: flexibleID,
                    name: "Flexible",
                    limit: try Money(600, currency: sgd),
                    purpose: .flexible
                ),
                BudgetNode(
                    id: rentID,
                    name: "Rent",
                    limit: try Money(1_500, currency: sgd),
                    purpose: .commitment
                ),
                BudgetNode(
                    id: debtID,
                    name: "Loan",
                    limit: try Money(400, currency: sgd),
                    purpose: .debt
                ),
                BudgetNode(
                    id: goalID,
                    name: "Emergency fund",
                    limit: try Money(300, currency: sgd),
                    purpose: .goal
                )
            ]
        )

        let summary = try XCTUnwrap(tree.planSummary(
            directSpending: [
                flexibleID: try Money(100, currency: sgd),
                rentID: try Money(1_500, currency: sgd),
                debtID: try Money(400, currency: sgd)
            ],
            purpose: .flexible
        ))

        XCTAssertEqual(summary.limit.amount, 600)
        XCTAssertEqual(summary.spent.amount, 100)
        XCTAssertEqual(summary.remaining.amount, 500)
        XCTAssertEqual(tree.categoryIDs(governedBy: .flexible), [flexibleID])
    }

    func testSpendingRollsUpThroughEveryAncestor() throws {
        let sgd = try CurrencyCode("SGD")
        let needsID = UUID()
        let foodID = UUID()
        let diningID = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [
                BudgetNode(
                    id: needsID,
                    name: "Needs",
                    limit: try Money(500, currency: sgd)
                ),
                BudgetNode(
                    id: foodID,
                    parentID: needsID,
                    name: "Food",
                    limit: try Money(200, currency: sgd)
                ),
                BudgetNode(
                    id: diningID,
                    parentID: foodID,
                    name: "Dining"
                )
            ]
        )

        let totals = try tree.rolledUpSpending(
            directSpending: [diningID: try Money(80, currency: sgd)]
        )

        XCTAssertEqual(totals[diningID]?.amount, 80)
        XCTAssertEqual(totals[foodID]?.amount, 80)
        XCTAssertEqual(totals[needsID]?.amount, 80)
    }

    func testParentAndChildLimitsAreNotAddedTogether() throws {
        let sgd = try CurrencyCode("SGD")
        let needsID = UUID()
        let foodID = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [
                BudgetNode(
                    id: needsID,
                    name: "Needs",
                    limit: try Money(500, currency: sgd)
                ),
                BudgetNode(
                    id: foodID,
                    parentID: needsID,
                    name: "Food",
                    limit: try Money(200, currency: sgd)
                )
            ]
        )

        let progress = try tree.progress(
            directSpending: [foodID: try Money(80, currency: sgd)]
        )
        let parent = try XCTUnwrap(progress.first { $0.node.id == needsID })
        let child = try XCTUnwrap(progress.first { $0.node.id == foodID })

        XCTAssertEqual(parent.remaining?.amount, 420)
        XCTAssertEqual(child.remaining?.amount, 120)
    }

    func testPlanSummaryIncludesChildOnlyLimitWithoutDoubleCounting() throws {
        let sgd = try CurrencyCode("SGD")
        let needsID = UUID()
        let foodID = UUID()
        let transportID = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [
                BudgetNode(id: needsID, name: "Needs"),
                BudgetNode(
                    id: foodID,
                    parentID: needsID,
                    name: "Food",
                    limit: try Money(200, currency: sgd)
                ),
                BudgetNode(id: transportID, parentID: needsID, name: "Transport")
            ]
        )

        let summary = try XCTUnwrap(
            tree.planSummary(
                directSpending: [
                    foodID: try Money(80, currency: sgd),
                    transportID: try Money(30, currency: sgd)
                ]
            )
        )

        XCTAssertEqual(summary.limit.amount, 200)
        XCTAssertEqual(summary.spent.amount, 80)
        XCTAssertEqual(summary.remaining.amount, 120)
        XCTAssertEqual(summary.unbudgetedSpent.amount, 30)
    }

    func testPlanSummaryUsesLimitedAncestorInsteadOfAddingChildAllocation() throws {
        let sgd = try CurrencyCode("SGD")
        let needsID = UUID()
        let foodID = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [
                BudgetNode(
                    id: needsID,
                    name: "Needs",
                    limit: try Money(500, currency: sgd)
                ),
                BudgetNode(
                    id: foodID,
                    parentID: needsID,
                    name: "Food",
                    limit: try Money(200, currency: sgd)
                )
            ]
        )

        let summary = try XCTUnwrap(
            tree.planSummary(
                directSpending: [foodID: try Money(80, currency: sgd)]
            )
        )

        XCTAssertEqual(summary.limit.amount, 500)
        XCTAssertEqual(summary.spent.amount, 80)
        XCTAssertEqual(summary.unbudgetedSpent.amount, 0)
    }

    func testCycleIsRejected() throws {
        let sgd = try CurrencyCode("SGD")
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertThrowsError(
            try BudgetTree(
                currency: sgd,
                nodes: [
                    BudgetNode(
                        id: firstID,
                        parentID: secondID,
                        name: "First"
                    ),
                    BudgetNode(
                        id: secondID,
                        parentID: firstID,
                        name: "Second"
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? BudgetTreeError,
                .cycle(nodeID: firstID)
            )
        }
    }

    func testDeepAcyclicHierarchyIsAcceptedWithoutQuadraticTraversal() throws {
        let sgd = try CurrencyCode("SGD")
        let nodeCount = 10_000
        let nodeIDs = (0..<nodeCount).map { _ in UUID() }
        let nodes = nodeIDs.enumerated().map { offset, nodeID in
            BudgetNode(
                id: nodeID,
                parentID: offset == 0 ? nil : nodeIDs[offset - 1],
                name: "Level \(offset)"
            )
        }

        let tree = try BudgetTree(currency: sgd, nodes: nodes)

        XCTAssertEqual(tree.nodes.count, nodeCount)
        XCTAssertEqual(tree.nodes.last?.parentID, nodeIDs[nodeCount - 2])
    }

    func testNegativeLimitIsRejected() throws {
        let sgd = try CurrencyCode("SGD")
        let nodeID = UUID()

        XCTAssertThrowsError(
            try BudgetTree(
                currency: sgd,
                nodes: [
                    BudgetNode(
                        id: nodeID,
                        name: "Invalid",
                        limit: try Money(-1, currency: sgd)
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? BudgetTreeError,
                .negativeLimit(nodeID: nodeID)
            )
        }
    }
}
