import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

enum ManagedAccountBalanceEditPolicy {
    static func shouldPersist(
        initial: Decimal?,
        edited: Decimal
    ) -> Bool {
        initial != edited
    }
}

struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var type: FinancialAccountType = .bank
    @State private var currencyCode = SupportedCurrencies.regionalDefault
    @State private var startingBalanceText = ""
    @State private var isSaving = false
    @State private var nameValidationMessage: String?
    @State private var balanceValidationMessage: String?
    @State private var errorMessage: String?

    private var startingBalance: Decimal? {
        parsedOpeningBalance(from: startingBalanceText, accountType: type)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("account.name", text: $name)
                        .moneyUpFieldValidation(nameValidationMessage)
                    if let nameValidationMessage {
                        MoneyUpFieldError(message: nameValidationMessage)
                    }
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
                                && type != .restrictedAllowance
                        )
                        .moneyUpFieldValidation(balanceValidationMessage)
                    if let balanceValidationMessage {
                        MoneyUpFieldError(message: balanceValidationMessage)
                    }
                } header: {
                    Text("account.opening_title")
                } footer: {
                    Text(type.openingBalanceGuidance)
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
                nameValidationMessage = nil
                balanceValidationMessage = nil
                errorMessage = nil
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func save() async {
        nameValidationMessage = nil
        balanceValidationMessage = nil
        errorMessage = nil
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            nameValidationMessage = AppLocalization.string("account.name_error")
            return
        }
        guard let startingBalance else {
            balanceValidationMessage = type.isLiabilityAccount
                ? AppLocalization.string("account.amount_owed_error")
                : AppLocalization.string("account.current_balance_error")
            return
        }
        isSaving = true
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
    @Environment(\.appReportingSnapshot) private var sharedReportingSnapshot
    let account: LedgerAccount

    @State private var name: String
    @State private var balanceText: String
    @State private var initialDisplayBalance: Decimal?
    @State private var targetID: UUID?
    @State private var pendingLifecycleAction: PendingLifecycleAction?
    @State private var isSaving = false
    @State private var nameValidationMessage: String?
    @State private var balanceValidationMessage: String?
    @State private var errorMessage: String?
    @State private var restrictedFundingRecords: [RestrictedAllowanceFundingRecord] = []
    @State private var fundingCorrection: RestrictedAllowanceFundingRecord?
    @State private var isLoadingRestrictedFunding = false

    init(account: LedgerAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _balanceText = State(initialValue: "")
        _initialDisplayBalance = State(initialValue: nil)
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
        return validatedManagedBalance(
            value,
            accountKind: currentAccount.kind,
            accountType: currentAccount.accountType,
            currentDisplayBalance: currentDisplayBalance
        )
    }

    private var currentDisplayBalance: Decimal? {
        guard case let .available(balance) =
            model.accountBalanceResultForPresentation(
                for: currentAccount,
                asOf: currentBalanceDate
            ) else { return nil }
        return balance.amount
    }

    private var currentBalanceDate: Date {
        sharedReportingSnapshot?.instant ?? model.currentDateForUserAction()
    }

    private var balanceLabel: LocalizedStringKey {
        currentAccount.kind == .liability ? "account.amount_owed" : "account.current_balance"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("lifecycle.name") {
                    TextField("account.name", text: $name)
                        .moneyUpFieldValidation(nameValidationMessage)
                    if let nameValidationMessage {
                        MoneyUpFieldError(message: nameValidationMessage)
                    }
                }
                Section {
                    TextField(balanceLabel, text: $balanceText)
                        .moneyAmountKeyboard(
                            currency: currentAccount.currency,
                            allowsNegative: currentAccount.kind != .liability
                                && currentAccount.accountType != .restrictedAllowance
                        )
                        .disabled(currentAccount.isArchived)
                        .moneyUpFieldValidation(balanceValidationMessage)
                    if let balanceValidationMessage {
                        MoneyUpFieldError(message: balanceValidationMessage)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if currentAccount.kind == .liability {
                            Text("account.amount_owed_detail")
                        } else if currentAccount.accountType == .restrictedAllowance {
                            Text("account.restricted_balance_management_detail")
                        } else if currentAccount.accountType == .brokerage
                            || currentAccount.accountType == .investment {
                            Text("account.investment_cash_detail")
                        } else {
                            Text("account.current_balance_detail")
                        }
                        Text("account.adjustment_detail")
                    }
                }

                restrictedFundingSection

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
            }
            .task(id: currentAccount.id) {
                await loadRestrictedFunding()
            }
            .sheet(item: $fundingCorrection) { record in
                RestrictedFundingCorrectionSheet(record: record) {
                    Task { await loadRestrictedFunding() }
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
                switch model.accountBalanceResultForPresentation(
                    for: currentAccount,
                    asOf: currentBalanceDate
                ) {
                case let .available(balance):
                    initialDisplayBalance = balance.amount
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
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    @ViewBuilder
    private var restrictedFundingSection: some View {
        if currentAccount.accountType == .restrictedAllowance {
            Section {
                if isLoadingRestrictedFunding {
                    ProgressView()
                } else if restrictedFundingRecords.isEmpty {
                    Text("account.restricted_funding_empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(restrictedFundingRecords) { record in
                        Button {
                            fundingCorrection = record
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(record.occurredAt.formattedForReporting(
                                        .dateTime.year().month().day(),
                                        calendar: model.reportingCalendar
                                    ))
                                    if let note = record.note {
                                        Text(note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(formattedMoney(record.amount))
                                    .monospacedDigit()
                            }
                        }
                        .disabled(currentAccount.isArchived)
                    }
                }
            } header: {
                Text("account.restricted_funding_history")
            } footer: {
                Text("account.restricted_funding_history_detail")
            }
        }
    }

    private func loadRestrictedFunding() async {
        guard currentAccount.accountType == .restrictedAllowance else { return }
        isLoadingRestrictedFunding = true
        defer { isLoadingRestrictedFunding = false }
        do {
            restrictedFundingRecords = try await model
                .restrictedAllowanceFundingRecords(accountID: currentAccount.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }

    private func save() async {
        nameValidationMessage = nil
        balanceValidationMessage = nil
        errorMessage = nil
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            nameValidationMessage = AppLocalization.string("account.name_error")
            return
        }
        let parsedBalance = decimalAmount(from: balanceText)
        let balanceChanged = parsedBalance.map {
            ManagedAccountBalanceEditPolicy.shouldPersist(
                initial: initialDisplayBalance,
                edited: $0
            )
        } ?? true
        let balance = balanceChanged ? editedBalance : parsedBalance
        guard let balance else {
            if currentAccount.accountType == .restrictedAllowance {
                balanceValidationMessage = AppLocalization.string(
                    "account.restricted_balance_management_error"
                )
            } else {
                balanceValidationMessage = currentAccount.kind == .liability
                    ? AppLocalization.string("account.amount_owed_error")
                    : AppLocalization.string("account.current_balance_error")
            }
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.renameLedgerItem(id: account.id, name: name)
            if !currentAccount.isArchived, balanceChanged {
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
            return AppLocalization.string("lifecycle.confirm_archive") + " " + base
        case .restore:
            return AppLocalization.string("lifecycle.confirm_restore")
        case .merge:
            return AppLocalization.string("lifecycle.confirm_merge") + " " + base
        case .deleteWithReassignment:
            return AppLocalization.string("lifecycle.confirm_reassign") + " " + base
        case .deleteUnused:
            return AppLocalization.string("lifecycle.confirm_delete")
        case nil:
            return ""
        }
    }

    private func performLifecycleAction() async {
        let action = pendingLifecycleAction
        pendingLifecycleAction = nil
        isSaving = true
        nameValidationMessage = nil
        balanceValidationMessage = nil
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
