import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var type: FinancialAccountType = .bank
    @State private var currencyCode = SupportedCurrencies.regionalDefault
    @State private var startingBalanceText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var startingBalance: Decimal? {
        parsedOpeningBalance(from: startingBalanceText, accountType: type)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("account.name", text: $name)
                    Picker("account.type", selection: $type) {
                        ForEach(FinancialAccountType.allCases, id: \.self) { item in
                            Label(item.localizedTitle, systemImage: item.systemImage)
                                .tag(item)
                        }
                    }
                } header: {
                    Text("account.details_title")
                } footer: {
                    Text("account.details_help")
                }

                Section {
                    SearchableCurrencyPicker(
                        title: "account.currency",
                        selection: $currencyCode,
                        existing: model.accounts.compactMap(\.currency)
                    )
                    TextField(type.openingBalanceLabel, text: $startingBalanceText)
                        .moneyAmountKeyboard(
                            currency: try? CurrencyCode(currencyCode),
                            allowsNegative: !type.isLiabilityAccount
                        )
                } header: {
                    Text("account.opening_title")
                } footer: {
                    Text(type.openingBalanceGuidance)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("account.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                currencyCode = model.profile?.baseCurrency.value ?? "SGD"
            }
            .onChange(of: type) { _, _ in
                errorMessage = nil
            }
        }
    }

    private func save() async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = String(localized: "account.name_error")
            return
        }
        guard let startingBalance else {
            errorMessage = type.isLiabilityAccount
                ? String(localized: "account.amount_owed_error")
                : String(localized: "account.current_balance_error")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.addAccount(
                name: name,
                type: type,
                currencyCode: currencyCode,
                startingBalance: startingBalance
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

struct AccountManagementSheet: View {
    private enum PendingLifecycleAction {
        case archive
        case restore
        case merge
        case deleteWithReassignment
        case deleteUnused
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let account: LedgerAccount

    @State private var name: String
    @State private var balanceText: String
    @State private var targetID: UUID?
    @State private var pendingLifecycleAction: PendingLifecycleAction?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(account: LedgerAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _balanceText = State(initialValue: "")
    }

    private var currentAccount: LedgerAccount {
        model.accounts.first { $0.id == account.id } ?? account
    }

    private var targets: [LedgerAccount] {
        model.compatibleLifecycleTargets(for: account.id)
    }

    private var impact: AppModel.LedgerItemLifecycleImpact {
        model.lifecycleImpact(for: account.id)
    }

    private var editedBalance: Decimal? {
        guard let value = decimalAmount(from: balanceText) else { return nil }
        guard currentAccount.kind != .liability || value >= .zero else { return nil }
        return value
    }

    private var balanceLabel: LocalizedStringKey {
        currentAccount.kind == .liability ? "account.amount_owed" : "account.current_balance"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("lifecycle.name") {
                    TextField("account.name", text: $name)
                }
                Section {
                    TextField(balanceLabel, text: $balanceText)
                        .moneyAmountKeyboard(
                            currency: currentAccount.currency,
                            allowsNegative: currentAccount.kind != .liability
                        )
                        .disabled(currentAccount.isArchived)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if currentAccount.kind == .liability {
                            Text("account.amount_owed_detail")
                        } else if currentAccount.accountType == .brokerage
                            || currentAccount.accountType == .investment {
                            Text("account.investment_cash_detail")
                        } else {
                            Text("account.current_balance_detail")
                        }
                        Text("account.adjustment_detail")
                    }
                }

                Section {
                    Button {
                        pendingLifecycleAction = currentAccount.isArchived
                            ? .restore : .archive
                    } label: {
                        Label {
                            Text(
                                currentAccount.isArchived
                                    ? LocalizedStringKey("lifecycle.restore")
                                    : LocalizedStringKey("lifecycle.archive")
                            )
                        } icon: {
                            Image(
                                systemName: currentAccount.isArchived
                                    ? "arrow.uturn.backward.circle" : "archivebox"
                            )
                        }
                    }

                    if !targets.isEmpty {
                        Picker("lifecycle.destination", selection: $targetID) {
                            ForEach(targets) { target in
                                Text(target.name).tag(Optional(target.id))
                            }
                        }

                        Button {
                            pendingLifecycleAction = .merge
                        } label: {
                            Label("lifecycle.merge", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(targetID == nil)

                        Button(role: .destructive) {
                            pendingLifecycleAction = .deleteWithReassignment
                        } label: {
                            Label(
                                "lifecycle.delete_reassign",
                                systemImage: "trash.slash"
                            )
                        }
                        .disabled(targetID == nil)
                    }

                    if impact.isUnused {
                        Button(role: .destructive) {
                            pendingLifecycleAction = .deleteUnused
                        } label: {
                            Label("lifecycle.delete_unused", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("lifecycle.manage")
                } footer: {
                    Text(impactSummary(impact))
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(currentAccount.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                guard balanceText.isEmpty else { return }
                targetID = targets.first?.id
                switch model.displayBalanceResult(for: currentAccount) {
                case let .available(balance):
                    balanceText = editableAmount(balance.amount)
                case let .unavailable(issue):
                    errorMessage = issue.localizedDescription
                }
            }
            .confirmationDialog(
                "lifecycle.confirm_title",
                isPresented: Binding(
                    get: { pendingLifecycleAction != nil },
                    set: { if !$0 { pendingLifecycleAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(confirmButtonTitle, role: confirmButtonRole) {
                    Task { await performLifecycleAction() }
                }
                Button("action.cancel", role: .cancel) {
                    pendingLifecycleAction = nil
                }
            } message: {
                Text(confirmMessage)
            }
        }
    }

    private func save() async {
        guard let balance = editedBalance else {
            errorMessage = currentAccount.kind == .liability
                ? String(localized: "account.amount_owed_error")
                : String(localized: "account.current_balance_error")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.renameLedgerItem(id: account.id, name: name)
            if !currentAccount.isArchived {
                try await model.setAccountBalance(
                    accountID: account.id,
                    displayBalance: balance
                )
            }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private var confirmButtonTitle: LocalizedStringKey {
        switch pendingLifecycleAction {
        case .archive: "lifecycle.archive"
        case .restore: "lifecycle.restore"
        case .merge: "lifecycle.merge"
        case .deleteWithReassignment: "lifecycle.delete_reassign"
        case .deleteUnused: "lifecycle.delete_unused"
        case nil: "action.okay"
        }
    }

    private var confirmButtonRole: ButtonRole? {
        switch pendingLifecycleAction {
        case .deleteWithReassignment, .deleteUnused: .destructive
        default: nil
        }
    }

    private var confirmMessage: String {
        let base = impactSummary(impact)
        switch pendingLifecycleAction {
        case .archive:
            return String(localized: "lifecycle.confirm_archive") + " " + base
        case .restore:
            return String(localized: "lifecycle.confirm_restore")
        case .merge:
            return String(localized: "lifecycle.confirm_merge") + " " + base
        case .deleteWithReassignment:
            return String(localized: "lifecycle.confirm_reassign") + " " + base
        case .deleteUnused:
            return String(localized: "lifecycle.confirm_delete")
        case nil:
            return ""
        }
    }

    private func performLifecycleAction() async {
        let action = pendingLifecycleAction
        pendingLifecycleAction = nil
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            switch action {
            case .archive:
                try await model.setLedgerItemArchived(id: account.id, isArchived: true)
            case .restore:
                try await model.setLedgerItemArchived(id: account.id, isArchived: false)
            case .merge:
                guard let targetID else { return }
                try await model.mergeLedgerItem(id: account.id, into: targetID)
                dismiss()
            case .deleteWithReassignment:
                guard let targetID else { return }
                try await model.deleteLedgerItem(
                    id: account.id,
                    reassigningTo: targetID
                )
                dismiss()
            case .deleteUnused:
                try await model.deleteLedgerItem(id: account.id)
                dismiss()
            case nil:
                return
            }
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
