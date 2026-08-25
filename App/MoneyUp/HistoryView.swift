import MoneyUpCore
import SwiftUI

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case expense
    case income
    case transfer
    case refund
    case adjustment

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "history.filter.all"
        case .expense: "transaction.expense"
        case .income: "transaction.income"
        case .transfer: "transaction.transfer"
        case .refund: "transaction.refund"
        case .adjustment: "transaction.adjustment"
        }
    }
}

private struct HistoryDayGroup: Identifiable {
    let date: Date
    let entries: [JournalEntry]
    var id: Date { date }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all
    @State private var selectedEntry: JournalEntry?
    @State private var entryPendingDeletion: JournalEntry?
    @State private var errorMessage: String?

    private var filteredEntries: [JournalEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.entries.filter { entry in
            matchesFilter(entry) && (query.isEmpty || searchableText(for: entry)
                .localizedCaseInsensitiveContains(query))
        }
    }

    private var dayGroups: [HistoryDayGroup] {
        Dictionary(grouping: filteredEntries) {
            Calendar.current.startOfDay(for: $0.occurredAt)
        }
        .map { HistoryDayGroup(date: $0.key, entries: $0.value) }
        .sorted { $0.date > $1.date }
    }

    private var unavailableTitle: LocalizedStringKey {
        searchText.isEmpty ? "history.empty" : "history.no_results"
    }

    private var unavailableDetail: LocalizedStringKey {
        searchText.isEmpty ? "history.empty_detail" : "history.no_results_detail"
    }

    var body: some View {
        NavigationStack {
            Group {
                if dayGroups.isEmpty {
                    ContentUnavailableView(
                        unavailableTitle,
                        systemImage: "clock.arrow.circlepath",
                        description: Text(unavailableDetail)
                    )
                } else {
                    List {
                        ForEach(dayGroups) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    Button {
                                        selectedEntry = entry
                                    } label: {
                                        TransactionRow(entry: entry)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            entryPendingDeletion = entry
                                        } label: {
                                            Label("action.delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                Text(group.date, format: .dateTime.weekday(.wide).month().day().year())
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("tab.history")
            .searchable(text: $searchText, prompt: "history.search")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("history.filter", selection: $filter) {
                        ForEach(HistoryFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .sheet(item: $selectedEntry) { entry in
                TransactionEditView(entry: entry)
            }
            .confirmationDialog(
                "transaction.delete_title",
                isPresented: Binding(
                    get: { entryPendingDeletion != nil },
                    set: { if !$0 { entryPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: entryPendingDeletion
            ) { entry in
                Button("action.delete", role: .destructive) {
                    entryPendingDeletion = nil
                    Task { await delete(entry) }
                }
                Button("action.cancel", role: .cancel) {}
            } message: { _ in
                Text("transaction.delete_detail")
            }
            .alert("error.could_not_save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("action.okay") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func matchesFilter(_ entry: JournalEntry) -> Bool {
        switch filter {
        case .all: true
        case .expense: entry.kind == .expense && !entry.isRefund(in: model.accounts)
        case .income: entry.kind == .income
        case .transfer: entry.kind == .transfer
        case .refund: entry.isRefund(in: model.accounts)
        case .adjustment: entry.kind == .adjustment || entry.kind == .investment
        }
    }

    private func searchableText(for entry: JournalEntry) -> String {
        let accountNames = entry.postings.compactMap { posting in
            model.accounts.first(where: { $0.id == posting.accountID })?.name
        }
        let amounts = entry.postings.map {
            NSDecimalNumber(decimal: $0.money.amount).stringValue
                + " " + $0.money.currency.value
        }
        return ([entry.payee, entry.note].compactMap { $0 } + accountNames + amounts)
            .joined(separator: " ")
    }

    private func delete(_ entry: JournalEntry) async {
        do {
            try await model.deleteEntry(id: entry.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EditableEntryValues {
    let kind: QuickLogKind
    let amount: Decimal
    let destinationAmount: Decimal?
    let accountID: UUID
    let destinationAccountID: UUID?
    let categoryID: UUID?

    init?(entry: JournalEntry, accounts: [LedgerAccount]) {
        let userIDs = Set(accounts.filter {
            $0.kind == .asset || $0.kind == .liability
        }.map(\.id))
        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        let incomeIDs = Set(accounts.filter { $0.kind == .income }.map(\.id))

        switch entry.kind {
        case .expense:
            guard let category = entry.postings.first(where: {
                expenseIDs.contains($0.accountID)
            }), let account = entry.postings.first(where: {
                userIDs.contains($0.accountID)
            }) else { return nil }
            kind = category.money.amount < .zero ? .refund : .expense
            amount = abs(category.money.amount)
            destinationAmount = nil
            accountID = account.accountID
            destinationAccountID = nil
            categoryID = category.accountID
        case .income:
            guard let category = entry.postings.first(where: {
                incomeIDs.contains($0.accountID)
            }), let account = entry.postings.first(where: {
                userIDs.contains($0.accountID)
            }) else { return nil }
            kind = .income
            amount = abs(category.money.amount)
            destinationAmount = nil
            accountID = account.accountID
            destinationAccountID = nil
            categoryID = category.accountID
        case .transfer:
            let userPostings = entry.postings.filter { userIDs.contains($0.accountID) }
            guard let source = userPostings.first(where: { $0.money.amount < .zero }),
                  let destination = userPostings.first(where: { $0.money.amount > .zero })
            else { return nil }
            kind = .transfer
            amount = abs(source.money.amount)
            destinationAmount = abs(destination.money.amount)
            accountID = source.accountID
            destinationAccountID = destination.accountID
            categoryID = nil
        case .adjustment, .investment:
            return nil
        }
    }
}

private struct TransactionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let entry: JournalEntry
    @State private var kind: QuickLogKind
    @State private var amountText: String
    @State private var destinationAmountText: String
    @State private var accountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var occurredAt: Date
    @State private var payee: String
    @State private var note: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    private let isEditable: Bool

    init(entry: JournalEntry) {
        self.entry = entry
        // The real extraction runs once the environment model is available.
        _kind = State(initialValue: .expense)
        _amountText = State(initialValue: "")
        _destinationAmountText = State(initialValue: "")
        _accountID = State(initialValue: nil)
        _destinationAccountID = State(initialValue: nil)
        _categoryID = State(initialValue: nil)
        _occurredAt = State(initialValue: entry.occurredAt)
        _payee = State(initialValue: entry.payee ?? "")
        _note = State(initialValue: entry.note ?? "")
        isEditable = entry.kind == .expense || entry.kind == .income || entry.kind == .transfer
    }

    private var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    private var sourceCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == accountID })?.currency
    }

    private var destinationCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == destinationAccountID })?.currency
    }

    private var needsDestinationAmount: Bool {
        kind == .transfer && sourceCurrency != destinationCurrency
            && sourceCurrency != nil && destinationCurrency != nil
    }

    private var canSave: Bool {
        guard isEditable,
              decimalAmount(from: amountText).map({ $0 > .zero }) == true,
              let accountID,
              model.userAccounts.contains(where: { $0.id == accountID }) else {
            return false
        }
        if kind == .transfer {
            guard let destinationAccountID,
                  destinationAccountID != accountID else { return false }
            return !needsDestinationAmount
                || decimalAmount(from: destinationAmountText).map { $0 > .zero } == true
        }
        return categories.contains { $0.id == categoryID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isEditable {
                    Picker("transaction.kind", selection: $kind) {
                        ForEach(QuickLogKind.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Section {
                        HStack {
                            TextField("quick_log.amount", text: $amountText)
                                .keyboardType(.decimalPad)
                            if let sourceCurrency {
                                Text(sourceCurrency.value).foregroundStyle(.secondary)
                            }
                        }
                        Picker(
                            kind == .transfer
                                ? "transaction.from_account"
                                : "transaction.account",
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
                            if needsDestinationAmount {
                                HStack {
                                    TextField(
                                        "transaction.received_amount",
                                        text: $destinationAmountText
                                    )
                                    .keyboardType(.decimalPad)
                                    if let destinationCurrency {
                                        Text(destinationCurrency.value)
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

                        DatePicker(
                            "transaction.date",
                            selection: $occurredAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        if kind != .transfer {
                            TextField("transaction.payee", text: $payee)
                        }
                        TextField("transaction.note", text: $note, axis: .vertical)
                    }
                } else {
                    Section {
                        TransactionRow(entry: entry)
                        Text("history.edit_not_supported")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("action.delete", role: .destructive) {
                        isConfirmingDelete = true
                    }
                }

                if let revisedAt = entry.revisedAt {
                    Section {
                        LabeledContent("history.last_edited") {
                            Text(revisedAt, format: .dateTime.month().day().year().hour().minute())
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("history.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                if isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("action.save") { Task { await save() } }
                            .disabled(!canSave || isSaving)
                    }
                }
            }
            .task { loadValues() }
            .onChange(of: kind) { _, _ in selectValidDefaults() }
            .confirmationDialog(
                "transaction.delete_title",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("action.delete", role: .destructive) {
                    Task { await delete() }
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("transaction.delete_detail")
            }
        }
    }

    private func loadValues() {
        guard let values = EditableEntryValues(entry: entry, accounts: model.accounts) else {
            return
        }
        kind = values.kind
        amountText = editableAmount(values.amount)
        destinationAmountText = values.destinationAmount.map { editableAmount($0) } ?? ""
        accountID = values.accountID
        destinationAccountID = values.destinationAccountID
        categoryID = values.categoryID
    }

    private func selectValidDefaults() {
        if !model.userAccounts.contains(where: { $0.id == accountID }) {
            accountID = model.userAccounts.first?.id
        }
        if kind == .transfer {
            if destinationAccountID == accountID
                || !model.userAccounts.contains(where: { $0.id == destinationAccountID }) {
                destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
            }
        } else if !categories.contains(where: { $0.id == categoryID }) {
            categoryID = categories.first?.id
        }
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText),
              let accountID else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.replaceEntry(
                id: entry.id,
                kind: kind,
                amount: amount,
                destinationAmount: decimalAmount(from: destinationAmountText),
                accountID: accountID,
                destinationAccountID: destinationAccountID,
                categoryID: categoryID,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        do {
            try await model.deleteEntry(id: entry.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension JournalEntry {
    func isRefund(in accounts: [LedgerAccount]) -> Bool {
        guard kind == .expense else { return false }
        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        return postings.contains {
            expenseIDs.contains($0.accountID) && $0.money.amount < .zero
        }
    }
}
