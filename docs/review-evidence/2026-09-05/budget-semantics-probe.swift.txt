import Foundation

let currency = try CurrencyCode("SGD")
let parentID = UUID(), groceryID = UUID(), diningID = UUID()
let spending = [groceryID: try Money(120, currency: currency), parentID: try Money(25, currency: currency)]

func snapshot(parent: Decimal?, groceries: Decimal, dining: Decimal) throws -> (BudgetProgress, BudgetPlanSummary) {
    let tree = try BudgetTree(currency: currency, nodes: [
        BudgetNode(id: parentID, name: "Food", limit: try parent.map { try Money($0, currency: currency) }),
        BudgetNode(id: groceryID, parentID: parentID, name: "Groceries", limit: try Money(groceries, currency: currency)),
        BudgetNode(id: diningID, parentID: parentID, name: "Dining", limit: try Money(dining, currency: currency))
    ])
    let progress = try tree.progress(directSpending: spending)
    guard let parentProgress = progress.first(where: { $0.node.id == parentID }),
          let summary = try tree.planSummary(directSpending: spending) else { fatalError("Missing result") }
    return (parentProgress, summary)
}
func display(_ value: Money?) -> String { value.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? "nil" }

for parentLimit: Decimal? in [nil, Decimal(500)] {
    for groceries: Decimal in [300, 400] {
        let (parent, summary) = try snapshot(parent: parentLimit, groceries: groceries, dining: 200)
        print("parent cap=\(parentLimit.map(String.init(describing:)) ?? "none"), groceries=\(groceries), dining=200 -> parent limit=\(display(parent.effectiveLimit)), parent spent=\(display(parent.spent)), plan limit=\(display(summary.limit)), plan spent=\(display(summary.spent)), unbudgeted=\(display(summary.unbudgetedSpent))")
        precondition(parent.spent.amount == 145)
        precondition(parent.effectiveLimit?.amount == parentLimit)
        precondition(summary.limit.amount == (parentLimit ?? (groceries + 200)))
    }
}

let before = try BudgetTree(currency: currency, nodes: [
    BudgetNode(id: parentID, name: "Food", limit: try Money(500, currency: currency)),
    BudgetNode(id: groceryID, parentID: parentID, name: "Groceries", limit: try Money(200, currency: currency))
])
// Apply the amount-combining operation from AppModelLedgerValidation.swift.
let mergedLimit = try before.nodes[0].limit!.adding(before.nodes[1].limit!)
let after = try BudgetTree(currency: currency, nodes: [BudgetNode(id: parentID, name: "Food", limit: mergedLimit)])
print("Current merge rule, child into parent: plan limit \(display(try before.planSummary(directSpending: [:])?.limit)) -> \(display(try after.planSummary(directSpending: [:])?.limit))")
let beforeTotal = try before.planSummary(directSpending: [:])!.limit.amount
precondition(beforeTotal == 500)
let afterTotal = try after.planSummary(directSpending: [:])!.limit.amount
precondition(afterTotal == 700)
print("PASS: 4 core budget cases; merge arithmetic demonstrated (not an app lifecycle test).")
