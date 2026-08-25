import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

struct AssetsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAddingAccount = false
    @State private var isAddingHolding = false
    @State private var editingAccount: LedgerAccount?
    @State private var isConfirmingExport = false
    @State private var isExporting = false
    @State private var exportDocument = CSVDocument(text: "")
    @State private var errorMessage: String?
    @State private var holdingPendingDeletion: InvestmentHolding?

    private var investmentAccounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.accountType == .investment || $0.accountType == .brokerage
        }
    }

    private var accountNetWorth: DerivedValue<Money> {
        guard let currency = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        var amount = Decimal.zero
        for account in model.userAccounts where account.currency == currency {
            switch model.displayBalanceResult(for: account) {
            case let .available(balance):
                amount += account.kind == .liability ? -balance.amount : balance.amount
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }
        return .money(
            amount,
            currency: currency,
            operation: "assets-account-net-worth"
        )
    }

    private var recordedHoldingsValue: DerivedValue<Money> {
        guard let currency = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        var amount = Decimal.zero
        for holding in model.investmentHoldings {
            do {
                guard let value = try holding.marketValue() else {
                    DerivedValueDiagnostics.record(
                        .holdingValuationFailed,
                        operation: "assets-recorded-holdings-missing-price"
                    )
                    return .unavailable(.holdingValuationFailed)
                }
                if value.currency == currency { amount += value.amount }
            } catch {
                DerivedValueDiagnostics.record(
                    .holdingValuationFailed,
                    operation: "assets-recorded-holdings",
                    error: error
                )
                return .unavailable(.holdingValuationFailed)
            }
        }
        return .money(
            amount,
            currency: currency,
            operation: "assets-recorded-holdings-total"
        )
    }

    private func value(for holding: InvestmentHolding) -> DerivedValue<Money> {
        do {
            guard let value = try holding.marketValue() else {
                DerivedValueDiagnostics.record(
                    .holdingValuationFailed,
                    operation: "assets-holding-row-missing-price"
                )
                return .unavailable(.holdingValuationFailed)
            }
            return .available(value)
        } catch {
            DerivedValueDiagnostics.record(
                .holdingValuationFailed,
                operation: "assets-holding-row",
                error: error
            )
            return .unavailable(.holdingValuationFailed)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("assets.account_net_worth")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        switch accountNetWorth {
                        case let .available(netWorth):
                            Text(formattedMoney(netWorth))
                                .font(.largeTitle.bold().monospacedDigit())
                        case let .unavailable(issue):
                            DerivedValueUnavailableView(
                                issue: issue,
                                prominent: true
                            )
                        }
                    }
                    .padding(.vertical, 8)
                } footer: {
                    Text("assets.account_net_worth_note")
                }

                Section("assets.accounts") {
                    ForEach(model.userAccounts) { account in
                        Button {
                            editingAccount = account
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: account.accountType?.systemImage ?? "wallet.bifold")
                                    .foregroundStyle(.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    Text(account.currency?.value ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                switch model.displayBalanceResult(for: account) {
                                case let .available(balance):
                                    Text(formattedMoney(balance))
                                        .font(.subheadline.monospacedDigit())
                                case let .unavailable(issue):
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("—")
                                            .font(.subheadline.monospacedDigit())
                                        Text(issue.localizedDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        isAddingAccount = true
                    } label: {
                        Label("account.add", systemImage: "plus.circle")
                    }
                }

                Section("assets.investments") {
                    if case let .available(value) = recordedHoldingsValue,
                       !value.isZero {
                        LabeledContent(
                            "assets.recorded_holdings",
                            value: formattedMoney(value)
                        )
                    } else if case let .unavailable(issue) = recordedHoldingsValue {
                        DerivedValueUnavailableView(issue: issue)
                    }
                    if model.investmentHoldings.isEmpty {
                        Text("assets.no_holdings")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.investmentHoldings) { holding in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(holding.symbol.isEmpty ? holding.name : holding.symbol)
                                        .fontWeight(.semibold)
                                    Text(holding.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    switch value(for: holding) {
                                    case let .available(value):
                                        Text(formattedMoney(value))
                                            .font(.subheadline.monospacedDigit())
                                    case let .unavailable(issue):
                                        Text("—")
                                            .font(.subheadline.monospacedDigit())
                                        Text(issue.localizedDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text(
                                        holding.quantity,
                                        format: .number.precision(.fractionLength(0...6))
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    holdingPendingDeletion = holding
                                } label: {
                                    Label("action.delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        isAddingHolding = true
                    } label: {
                        Label("holding.add", systemImage: "plus.circle")
                    }
                    .disabled(investmentAccounts.isEmpty)

                    if investmentAccounts.isEmpty {
                        Text("holding.add_investment_account_first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("assets.data") {
                    NavigationLink {
                        DataSafetyView()
                    } label: {
                        Label("backup.data_safety", systemImage: "externaldrive.badge.shield.checkmark")
                    }

                    Button {
                        isConfirmingExport = true
                    } label: {
                        Label("export.csv", systemImage: "tablecells")
                    }

                    Button {
                        model.lock()
                    } label: {
                        Label("lock.lock_now", systemImage: "lock.fill")
                    }

                    LabeledContent {
                        Text(AppVersion.display).monospacedDigit()
                    } label: {
                        Label("assets.version", systemImage: "info.circle")
                    }

                    NavigationLink {
                        PrivacyAndBetaView()
                    } label: {
                        Label("privacy.title", systemImage: "hand.raised.fill")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("tab.assets")
            .sheet(isPresented: $isAddingAccount) {
                AddAccountSheet()
            }
            .sheet(isPresented: $isAddingHolding) {
                AddHoldingSheet(accounts: investmentAccounts)
            }
            .sheet(item: $editingAccount) { account in
                AccountBalanceSheet(account: account)
            }
            .confirmationDialog(
                "export.warning_title",
                isPresented: $isConfirmingExport,
                titleVisibility: .visible
            ) {
                Button("export.continue") {
                    exportDocument = CSVDocument(text: model.csvExport())
                    isExporting = true
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("export.warning_detail")
            }
            .confirmationDialog(
                "holding.delete_title",
                isPresented: Binding(
                    get: { holdingPendingDeletion != nil },
                    set: { if !$0 { holdingPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: holdingPendingDeletion
            ) { holding in
                Button("action.delete", role: .destructive) {
                    holdingPendingDeletion = nil
                    Task { await delete(holding) }
                }
                Button("action.cancel", role: .cancel) {
                    holdingPendingDeletion = nil
                }
            } message: { _ in
                Text("holding.delete_detail")
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "MoneyUp-Ledger"
            ) { result in
                if case let .failure(error) = result {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func delete(_ holding: InvestmentHolding) async {
        do {
            try await model.deleteInvestmentHolding(id: holding.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var type: FinancialAccountType = .bank
    @State private var currencyCode = "SGD"
    @State private var startingBalanceText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var startingBalance: Decimal? {
        let trimmed = startingBalanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .zero }
        guard let value = decimalAmount(from: trimmed), value >= .zero else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("account.name", text: $name)
                Picker("account.type", selection: $type) {
                    ForEach(FinancialAccountType.allCases, id: \.self) { item in
                        Text(item.localizedTitle).tag(item)
                    }
                }
                TextField("account.currency", text: $currencyCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("account.starting_balance", text: $startingBalanceText)
                    .keyboardType(.decimalPad)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("account.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || startingBalance == nil
                                || isSaving
                        )
                }
            }
            .onAppear {
                currencyCode = model.profile?.baseCurrency.value ?? "SGD"
            }
        }
    }

    private func save() async {
        guard let startingBalance else {
            errorMessage = String(localized: "error.invalid_amount")
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
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountBalanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let account: LedgerAccount

    @State private var balanceText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(account: LedgerAccount) {
        self.account = account
        _balanceText = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("account.current_balance", text: $balanceText)
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if account.accountType == .brokerage
                            || account.accountType == .investment {
                            Text("account.investment_cash_detail")
                        }
                        Text("account.adjustment_detail")
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(decimalAmount(from: balanceText) == nil || isSaving)
                }
            }
            .onAppear {
                guard balanceText.isEmpty else { return }
                switch model.displayBalanceResult(for: account) {
                case let .available(balance):
                    balanceText = editableAmount(balance.amount)
                case let .unavailable(issue):
                    errorMessage = issue.localizedDescription
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        guard let balance = decimalAmount(from: balanceText) else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.setAccountBalance(accountID: account.id, displayBalance: balance)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AddHoldingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let accounts: [LedgerAccount]

    @State private var accountID: UUID?
    @State private var symbol = ""
    @State private var name = ""
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var currencyCode = "SGD"
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        accountID != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && decimalAmount(from: quantityText) != nil
            && decimalAmount(from: priceText) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("transaction.account", selection: $accountID) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                TextField("holding.symbol", text: $symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("holding.name", text: $name)
                TextField("holding.quantity", text: $quantityText)
                    .keyboardType(.decimalPad)
                TextField("holding.price", text: $priceText)
                    .keyboardType(.decimalPad)
                TextField("account.currency", text: $currencyCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("holding.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .onAppear {
                accountID = accounts.first?.id
                currencyCode = model.profile?.baseCurrency.value ?? "SGD"
            }
        }
    }

    private func save() async {
        guard let accountID,
              let quantity = decimalAmount(from: quantityText),
              let price = decimalAmount(from: priceText) else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let holding = try InvestmentHolding(
                accountID: accountID,
                symbol: symbol,
                name: name,
                quantity: quantity,
                price: try Money(price, currency: CurrencyCode(currencyCode)),
                priceAsOf: Date()
            )
            try await model.addInvestmentHolding(holding)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
