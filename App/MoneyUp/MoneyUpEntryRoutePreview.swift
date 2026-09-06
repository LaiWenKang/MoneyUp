import SwiftUI

struct MoneyUpEntryRoute: Equatable {
    let source: MoneyUpFlowNode
    let destination: MoneyUpFlowNode

    static func make(kind: QuickLogKind, account: String, destination: String, category: String) -> Self {
        let accountNode = MoneyUpFlowNode(title: account, symbol: "wallet.bifold")
        let categoryNode = MoneyUpFlowNode(title: category, symbol: "square.grid.2x2")
        switch kind {
        case .expense: return Self(source: accountNode, destination: categoryNode)
        case .income, .refund: return Self(source: categoryNode, destination: accountNode)
        case .transfer: return Self(source: accountNode, destination: MoneyUpFlowNode(title: destination, symbol: "wallet.bifold"))
        }
    }
}

struct MoneyUpEntryRoutePreview: View {
    let kind: QuickLogKind
    let account: String?
    let destination: String?
    let category: String?

    var body: some View {
        let route = MoneyUpEntryRoute.make(
            kind: kind,
            account: account ?? AppLocalization.string("transaction.account"),
            destination: destination ?? AppLocalization.string("transaction.to_account"),
            category: category ?? AppLocalization.string("transaction.category")
        )
        MoneyUpFlowDiagram(source: route.source, destination: route.destination)
            .foregroundStyle(.primary)
            .padding(.vertical, 6)
    }
}
