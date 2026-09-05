import Foundation
import MoneyUpCore
import XCTest

final class AutomaticBudgetTests: XCTestCase {
    func testDirectUnallocatedSpendingReducesFlexibleGuidance() throws {
        let sgd = try CurrencyCode("SGD")
        let parent = BudgetNode(name: "Food", purpose: .flexible, allocationMode: .automatic)
        let child = BudgetNode(parentID: parent.id, name: "Dining", limit: try Money(300, currency: sgd), purpose: .flexible, allocationMode: .automatic)
        let tree = try BudgetTree(currency: sgd, nodes: [parent, child])
        let spending = [parent.id: try Money(10, currency: sgd), child.id: try Money(120, currency: sgd)]
        let summary = try XCTUnwrap(tree.planSummary(directSpending: spending, purpose: .flexible))
        XCTAssertEqual(summary.remaining.amount, 170)
        XCTAssertTrue(tree.categoryIDs(governedBy: .flexible).contains(parent.id))
        XCTAssertTrue(tree.nodesNeedingPurpose(directSpending: spending).isEmpty)
    }

    func testUnclassifiedDirectSpendingRequiresReviewBeforeGuidance() throws {
        let sgd = try CurrencyCode("SGD")
        let parent = BudgetNode(name: "Food", allocationMode: .automatic)
        let child = BudgetNode(parentID: parent.id, name: "Dining", limit: try Money(300, currency: sgd), purpose: .flexible, allocationMode: .automatic)
        let tree = try BudgetTree(currency: sgd, nodes: [parent, child])
        XCTAssertEqual(tree.nodesNeedingPurpose(directSpending: [parent.id: try Money(10, currency: sgd)]), [parent.id])
    }

    func testDirectParentAndChildrenRecalculateWithoutDuplicatingTotals() throws {
        let sgd = try CurrencyCode("SGD")
        let parent = BudgetNode(name: "Food", limit: try Money(100, currency: sgd), allocationMode: .automatic)
        var child = BudgetNode(parentID: parent.id, name: "Groceries", limit: try Money(300, currency: sgd), allocationMode: .automatic)
        let dining = BudgetNode(parentID: parent.id, name: "Dining", limit: try Money(200, currency: sgd), allocationMode: .automatic)
        let spending = [parent.id: try Money(25, currency: sgd), child.id: try Money(120, currency: sgd), dining.id: try Money(100, currency: sgd)]
        for amount: Decimal in [300, 400, 50, 0] {
            child.limit = try Money(amount, currency: sgd)
            let tree = try BudgetTree(currency: sgd, nodes: [parent, child, dining])
            let rows = try tree.progress(directSpending: spending)
            let root = try XCTUnwrap(rows.first { $0.node.id == parent.id })
            let summary = try XCTUnwrap(tree.planSummary(directSpending: spending))
            XCTAssertEqual(root.effectiveLimit?.amount, 300 + amount)
            XCTAssertEqual(root.spent.amount, 245)
            XCTAssertEqual(root.remaining?.amount, 55 + amount)
            XCTAssertEqual(root.directRemaining?.amount, 75)
            XCTAssertEqual(summary.limit, root.effectiveLimit)
            XCTAssertEqual(summary.spent, root.spent)
            XCTAssertEqual(summary.remaining, root.remaining)
            XCTAssertEqual(rows.first { $0.node.id == child.id }?.remaining?.amount, amount - 120)
        }
    }

    func testUncappedParentDisplaysItsChildrenWhileLegacyCapStaysFixed() throws {
        let sgd = try CurrencyCode("SGD")
        var parent = BudgetNode(name: "Food")
        let child = BudgetNode(parentID: parent.id, name: "Groceries", limit: try Money(200, currency: sgd))
        let uncapped = try BudgetTree(currency: sgd, nodes: [parent, child])
        XCTAssertEqual(try uncapped.progress(directSpending: [:])[0].effectiveLimit?.amount, 200)
        parent.limit = try Money(500, currency: sgd)
        let capped = try BudgetTree(currency: sgd, nodes: [parent, child])
        XCTAssertEqual(try capped.planSummary(directSpending: [:])?.limit.amount, 500)
        XCTAssertEqual(try BudgetModeConversion.limit(parent.limit, children: child.limit, from: .fixedTotal, to: .automatic)?.amount, 300)
    }

    func testMonthAndCurrencyOverridesAreIndependentAndRoundTrip() throws {
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        let september = try BudgetMonth(year: 2026, month: 9)
        let october = try BudgetMonth(year: 2026, month: 10)
        var node = BudgetNode(name: "Food", limit: try Money(500, currency: sgd))
        try node.setMonthlyAllocation(MonthlyBudgetAllocation(
            month: september, currency: sgd, limit: Money(600, currency: sgd)))
        try node.setMonthlyAllocation(MonthlyBudgetAllocation(
            month: september, currency: usd, limit: Money(80, currency: usd)))
        try node.setMonthlyAllocation(MonthlyBudgetAllocation(
            month: october, currency: sgd, limit: nil))
        let restored = try JSONDecoder().decode(BudgetNode.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(restored, node)
        XCTAssertEqual(restored.resolved(for: september, currency: sgd).limit?.amount, 600)
        XCTAssertEqual(restored.resolved(for: september, currency: usd).limit?.amount, 80)
        XCTAssertNil(restored.resolved(for: october, currency: sgd).limit)
        XCTAssertNil(restored.resolved(for: october, currency: usd).limit)
        XCTAssertEqual(restored.limit?.amount, 500)
        XCTAssertEqual(restored.allocationMode, .fixedTotal)
    }

    func testLegacyPayloadRetainsCapAndNoOverrides() throws {
        let node = BudgetNode(name: "Food", limit: try Money(500, currency: CurrencyCode("SGD")))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        payload.removeValue(forKey: "allocationMode")
        payload.removeValue(forKey: "monthlyAllocations")
        let restored = try JSONDecoder().decode(BudgetNode.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(restored.allocationMode, .fixedTotal)
        XCTAssertEqual(restored.limit?.amount, 500)
        XCTAssertTrue(restored.monthlyAllocations.isEmpty)
    }

    func testParentChildMergesConserveFiveHundredInBothDirections() throws {
        let sgd = try CurrencyCode("SGD")
        let parent = BudgetNode(name: "Food", limit: try Money(500, currency: sgd))
        let child = BudgetNode(parentID: parent.id, name: "Dining", limit: try Money(200, currency: sgd))
        for (source, target) in [(parent.id, child.id), (child.id, parent.id)] {
            var merged = try BudgetMergePlanner.mergedNode(sourceID: source, targetID: target, nodes: [parent, child], currency: sgd)
            merged.parentID = nil
            let tree = try BudgetTree(currency: sgd, nodes: [merged])
            XCTAssertEqual(try tree.planSummary(directSpending: [:])?.limit.amount, 500)
            XCTAssertEqual(merged.allocationMode, .automatic)
        }
    }

    func testMergePreservesChildrenAndMonthlyCurrencyAllocations() throws {
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        let month = try BudgetMonth(year: 2026, month: 9)
        var source = BudgetNode(name: "Food", limit: try Money(500, currency: sgd))
        var target = BudgetNode(name: "Travel", limit: try Money(300, currency: sgd))
        var child = BudgetNode(parentID: source.id, name: "Dining", limit: try Money(200, currency: sgd))
        try source.setMonthlyAllocation(MonthlyBudgetAllocation(month: month, currency: usd, limit: Money(90, currency: usd)))
        try target.setMonthlyAllocation(MonthlyBudgetAllocation(month: month, currency: usd, limit: Money(40, currency: usd)))
        let merged = try BudgetMergePlanner.mergedNode(sourceID: source.id, targetID: target.id, nodes: [source, target, child], currency: sgd)
        child.parentID = target.id
        let tree = try BudgetTree(currency: sgd, nodes: [merged, child])
        XCTAssertEqual(try tree.planSummary(directSpending: [:])?.limit.amount, 800)
        let foreign = try BudgetTree(currency: usd, nodes: [merged, child], month: month)
        XCTAssertEqual(try foreign.planSummary(directSpending: [:])?.limit.amount, 130)
    }

    func testOverallocatedCapRequiresMergeReview() throws {
        let sgd = try CurrencyCode("SGD")
        let parent = BudgetNode(name: "Food", limit: try Money(100, currency: sgd))
        let child = BudgetNode(parentID: parent.id, name: "Dining", limit: try Money(200, currency: sgd))
        XCTAssertThrowsError(try BudgetMergePlanner.mergedNode(sourceID: child.id, targetID: parent.id, nodes: [parent, child], currency: sgd)) {
            XCTAssertEqual($0 as? BudgetMergeError, .overallocatedEnvelope)
        }
    }

    func testRolloverOfDirectAllocationsNeverCountsChildSpendingTwice() throws {
        let sgd = try CurrencyCode("SGD")
        let calendar = FinancialPeriodBoundary.gregorianCalendar()
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let february = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: january))
        let parent = BudgetNode(name: "Food", limit: try Money(100, currency: sgd), rolloverRule: .positiveOnly, rolloverStartedAt: january, allocationMode: .automatic)
        let child = BudgetNode(parentID: parent.id, name: "Dining", limit: try Money(200, currency: sgd), rolloverRule: .positiveOnly, rolloverStartedAt: january, allocationMode: .automatic)
        let tree = try BudgetTree(currency: sgd, nodes: [parent, child])
        let carry = try BudgetRolloverEngine.snapshot(tree: tree, monthlySpending: [MonthlyBudgetSpending(monthStart: january, directSpending: [parent.id: Money(10, currency: sgd), child.id: Money(50, currency: sgd)])], asOf: february, calendar: calendar)
        XCTAssertEqual(carry.carryIn[parent.id]?.amount, 90)
        XCTAssertEqual(carry.carryIn[child.id]?.amount, 150)
        XCTAssertEqual(try tree.progress(directSpending: [:], effectiveLimits: carry.effectiveLimits)[0].effectiveLimit?.amount, 540)
        var unallocatedChild = child
        unallocatedChild.limit = nil
        let generalTree = try BudgetTree(currency: sgd, nodes: [parent, unallocatedChild])
        let generalCarry = try BudgetRolloverEngine.snapshot(
            tree: generalTree,
            monthlySpending: [MonthlyBudgetSpending(monthStart: january, directSpending: [child.id: Money(50, currency: sgd)])],
            asOf: february, calendar: calendar
        )
        XCTAssertEqual(generalCarry.carryIn[parent.id]?.amount, 50)
        var fixedParent = parent
        fixedParent.limit = try Money(300, currency: sgd)
        fixedParent.allocationMode = .fixedTotal
        XCTAssertThrowsError(try BudgetMergePlanner.validateRolloverScopes(
            before: [fixedParent, child], after: [parent, child], affectedIDs: [parent.id]
        )) { XCTAssertEqual($0 as? BudgetMergeError, .rolloverRequiresReview) }
    }

    func testDeepOutlineAndAggregateDoNotRecurse() throws {
        let sgd = try CurrencyCode("SGD")
        var nodes: [BudgetNode] = []
        for index in 0..<10_000 {
            nodes.append(BudgetNode(parentID: nodes.last?.id, name: "\(index)", limit: index == 9_999 ? try Money(1, currency: sgd) : nil, allocationMode: .automatic))
        }
        let tree = try BudgetTree(currency: sgd, nodes: nodes)
        XCTAssertEqual(BudgetOutline.items(nodes).count, nodes.count)
        XCTAssertEqual(try tree.progress(directSpending: [:])[0].effectiveLimit?.amount, 1)
    }

    func testVisibilityIsIndependentAndDoesNotMutateTheBudget() throws {
        let parent = UUID(), child = UUID()
        var preferences = MoneyUpDisplayPreferences()
        preferences.setGuidanceVisible(false, for: parent)
        XCTAssertFalse(preferences.showsGuidance(for: parent))
        XCTAssertTrue(preferences.showsGuidance(for: child))
        preferences.showsDailyGuidance = false
        XCTAssertFalse(preferences.showsGuidance(for: child))
        preferences = try JSONDecoder().decode(MoneyUpDisplayPreferences.self, from: JSONEncoder().encode(preferences))
        preferences.showsDailyGuidance = true
        XCTAssertFalse(preferences.showsGuidance(for: parent))
        XCTAssertTrue(preferences.showsGuidance(for: child))
    }
}
