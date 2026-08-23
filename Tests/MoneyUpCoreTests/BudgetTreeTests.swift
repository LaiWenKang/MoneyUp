import Foundation
@testable import MoneyUpCore
import XCTest

final class BudgetTreeTests: XCTestCase {
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
            guard let budgetError = error as? BudgetTreeError else {
                return XCTFail("Expected a budget error, got \(error)")
            }
            guard case .cycle = budgetError else {
                return XCTFail("Expected a budget cycle error, got \(error)")
            }
        }
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
