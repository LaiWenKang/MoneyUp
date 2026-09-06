import SwiftUI

/// Benefits live with account management, but only linked prepaid balances
/// qualify as stored value. This section never adds limits or claims to cash.
struct AssetAllowancesSection: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false

    var body: some View {
        Section {
            ForEach(model.allowancePlans.filter { !$0.isArchived }) { plan in
                NavigationLink {
                    AllowanceDetailView(planID: plan.id)
                } label: {
                    AllowanceRow(plan: plan)
                }
            }
            Button { isAdding = true } label: {
                Label("allowance.add", systemImage: "plus.circle")
            }
            if model.allowancePlans.contains(where: \.isArchived) {
                NavigationLink {
                    AllowanceCenterView()
                } label: {
                    Label("allowance.manage_all", systemImage: "archivebox")
                }
            }
        } header: {
            Text("allowance.title")
        } footer: {
            MoneyUpExplainer("allowance.assets_detail")
        }
        .sheet(isPresented: $isAdding) { AllowanceEditorSheet(plan: nil) }
    }
}
