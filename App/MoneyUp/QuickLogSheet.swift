import Foundation
import MoneyUpCore
import PhotosUI
import SwiftUI

enum QuickLogKind: String, CaseIterable, Identifiable {
    case expense
    case income
    case transfer

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .expense: "transaction.expense"
        case .income: "transaction.income"
        case .transfer: "transaction.transfer"
        }
    }
}

struct QuickLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FocusState private var isAmountFocused: Bool

    @State private var kind: QuickLogKind
    @State private var amountText = ""
    @State private var destinationAmountText = ""
    @State private var accountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var occurredAt = Date()
    @State private var payee = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var smartText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var smartMessage: String?

    init(initialKind: QuickLogKind = .expense) {
        _kind = State(initialValue: initialKind)
    }

    private var amount: Decimal? {
        guard let value = decimalAmount(from: amountText), value > .zero else { return nil }
        return value
    }

    private var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    private var selectedAccountCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == accountID })?.currency
    }

    private var selectedDestinationCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == destinationAccountID })?.currency
    }

    private var isForeignCurrencyTransfer: Bool {
        kind == .transfer
            && selectedAccountCurrency != nil
            && selectedDestinationCurrency != nil
            && selectedAccountCurrency != selectedDestinationCurrency
    }

    private var destinationAmount: Decimal? {
        guard let value = decimalAmount(from: destinationAmountText), value > .zero else {
            return nil
        }
        return value
    }

    private var canSave: Bool {
        guard amount != nil, accountID != nil else { return false }
        switch kind {
        case .expense, .income:
            return categoryID != nil
        case .transfer:
            return destinationAccountID != nil
                && destinationAccountID != accountID
                && (!isForeignCurrencyTransfer || destinationAmount != nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("transaction.kind", selection: $kind) {
                    ForEach(QuickLogKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if kind != .transfer {
                    smartEntrySection
                }

                Section {
                    TextField("quick_log.amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                        .focused($isAmountFocused)

                    Picker(
                        kind == .transfer ? "transaction.from_account" : "transaction.account",
                        selection: $accountID
                    ) {
                        ForEach(model.userAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }

                    if kind == .transfer {
                        Picker("transaction.to_account", selection: $destinationAccountID) {
                            ForEach(model.userAccounts.filter { $0.id != accountID }) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                        if isForeignCurrencyTransfer {
                            HStack {
                                TextField(
                                    "transaction.received_amount",
                                    text: $destinationAmountText
                                )
                                .keyboardType(.decimalPad)
                                if let currency = selectedDestinationCurrency {
                                    Text(currency.value)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Picker("transaction.category", selection: $categoryID) {
                            ForEach(categories) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                    }
                }

                Section {
                    DatePicker(
                        "quick_log.date",
                        selection: $occurredAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    if kind != .transfer {
                        TextField("transaction.payee", text: $payee)
                    }
                    TextField("quick_log.note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if model.userAccounts.isEmpty {
                    Section {
                        Text("transaction.no_accounts")
                            .foregroundStyle(.secondary)
                    }
                } else if kind == .transfer && model.userAccounts.count < 2 {
                    Section {
                        Text("transaction.need_two_accounts")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("quick_log.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .onAppear {
                selectDefaults()
                isAmountFocused = true
            }
            .onChange(of: kind) { _, _ in selectDefaults() }
            .onChange(of: photoItem) { _, item in
                Task { await scanReceipt(item) }
            }
            .onChange(of: accountID) { _, _ in
                if destinationAccountID == accountID {
                    destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.large])
    }

    private var smartEntrySection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                TextField("quick_log.smart_placeholder", text: $smartText, axis: .vertical)
                    .lineLimit(1...3)
                Button("quick_log.smart_fill") { applyTypedPhrase() }
                    .buttonStyle(.borderless)
                    .disabled(
                        smartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("quick_log.scan_receipt", systemImage: "doc.text.viewfinder")
            }
            .disabled(isScanning)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("quick_log.scanning").foregroundStyle(.secondary)
                }
            }

            if let smartMessage {
                Text(smartMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("quick_log.smart_entry")
        } footer: {
            Text("quick_log.smart_footer")
        }
    }

    /// `dd/mm` and `mm/dd` cannot be told apart from the digits alone, so the
    /// reader follows whatever order this locale writes dates in.
    private static var localePrefersDayFirst: Bool {
        let format = DateFormatter.dateFormat(
            fromTemplate: "yMd",
            options: 0,
            locale: .current
        ) ?? "d/M/y"
        guard let day = format.firstIndex(of: "d"),
              let month = format.firstIndex(of: "M") else { return true }
        return day < month
    }

    private func applyTypedPhrase() {
        let draft = NaturalLanguageEntryParser.draft(
            from: smartText,
            accounts: model.accounts,
            prefersDayFirst: Self.localePrefersDayFirst
        )
        if apply(draft) { smartText = "" }
    }

    private func scanReceipt(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isScanning = true
        smartMessage = nil
        defer {
            isScanning = false
            photoItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReceiptScannerError.unreadableImage
            }
            let lines = try await ReceiptScanner.recognizeLines(inImageData: data)
            _ = apply(
                ReceiptTextParser.draft(
                    fromLines: lines,
                    prefersDayFirst: Self.localePrefersDayFirst
                )
            )
        } catch {
            smartMessage = error.localizedDescription
        }
    }

    /// Applies whatever the reader was sure about and leaves the rest alone.
    /// Returns false when nothing was recognized, so the caller can keep the
    /// user's input instead of clearing it.
    @discardableResult
    private func apply(_ draft: TransactionDraft) -> Bool {
        guard !draft.isEmpty else {
            smartMessage = String(localized: "quick_log.smart_nothing_found")
            return false
        }

        kind = draft.kind == .income ? .income : .expense
        if let amount = draft.amount {
            amountText = amount.formatted(
                .number.precision(.fractionLength(0...2)).grouping(.never)
            )
        }
        if let parsedDate = draft.occurredAt { occurredAt = parsedDate }
        if let parsedPayee = draft.payee { payee = parsedPayee }
        if let parsedAccount = draft.accountID { accountID = parsedAccount }

        if let parsedCategory = draft.categoryID {
            categoryID = parsedCategory
        } else if let parsedPayee = draft.payee,
                  let learned = CategorySuggester.suggestedCategory(
                      forPayee: parsedPayee,
                      kind: draft.kind == .income ? .income : .expense,
                      entries: model.entries,
                      accounts: model.accounts
                  ) {
            categoryID = learned
        }

        smartMessage = nil
        isAmountFocused = false
        return true
    }

    /// Fills what is still unset. It must not overwrite a value the user or a
    /// parsed draft already chose, because it also runs when the kind changes.
    private func selectDefaults() {
        accountID = accountID ?? model.userAccounts.first?.id
        switch kind {
        case .expense:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryID = model.expenseCategories.first { $0.parentID != nil }?.id
                    ?? model.expenseCategories.first?.id
            }
        case .income:
            if !model.incomeCategories.contains(where: { $0.id == categoryID }) {
                categoryID = model.incomeCategories.first?.id
            }
        case .transfer:
            destinationAccountID = destinationAccountID
                ?? model.userAccounts.first { $0.id != accountID }?.id
        }
    }

    private func save() async {
        guard let amount, let accountID else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            switch kind {
            case .expense:
                guard let categoryID else { return }
                try await model.logExpense(
                    amount: amount,
                    accountID: accountID,
                    categoryID: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            case .income:
                guard let categoryID else { return }
                try await model.logIncome(
                    amount: amount,
                    accountID: accountID,
                    categoryID: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            case .transfer:
                guard let destinationAccountID else { return }
                try await model.logTransfer(
                    amount: amount,
                    destinationAmount: isForeignCurrencyTransfer ? destinationAmount : nil,
                    sourceAccountID: accountID,
                    destinationAccountID: destinationAccountID,
                    occurredAt: occurredAt,
                    note: note
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
