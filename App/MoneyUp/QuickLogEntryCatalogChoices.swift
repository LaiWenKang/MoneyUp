import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    @ViewBuilder
    var missingEntryCategoryGuidance: some View {
        if kind == .expense || kind == .refund, categories.isEmpty {
            Section {
                NavigationLink { EntryCatalogView(scope: .expenses) }
                label: { Label("catalog.expenses_title", systemImage: "switch.2") }
            }
        }
    }

    @ViewBuilder
    var missingEntryAccountGuidance: some View {
        if recordingAccounts.isEmpty {
            Section {
                NavigationLink { EntryCatalogView(scope: .accounts) }
                label: { Label("catalog.accounts_title", systemImage: "switch.2") }
                Button("account.add") { isAddingAccount = true }
                Text(model.userAccounts.isEmpty ? "transaction.no_accounts" : "catalog.no_visible_accounts")
                    .foregroundStyle(.secondary)
            }
        } else if kind == .transfer
                    && (sourceAccounts.isEmpty || recordingAccounts.count < 2) {
            Section {
                Button("account.add") { isAddingAccount = true }
                NavigationLink { EntryCatalogView(scope: .accounts) }
                label: { Label("catalog.accounts_title", systemImage: "switch.2") }
                Text("transaction.need_two_accounts")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
