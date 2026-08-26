import MoneyUpCore
import SwiftUI

struct HistoryPreset: Equatable {
    let categoryID: UUID?
    let interval: DateInterval?

    init(categoryID: UUID? = nil, interval: DateInterval? = nil) {
        self.categoryID = categoryID
        self.interval = interval
    }
}

private extension HistoryKindFilter {
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

private struct HistoryFilterDraft: Equatable {
    var kind: HistoryKindFilter = .all
    var accountID: UUID?
    var categoryID: UUID?
    var includesStartDate = false
    var startDate: Date
    var includesEndDate = false
    var endDate: Date
    var minimumAmountText = ""
    var maximumAmountText = ""

    init(
        now: Date = Date(),
        calendar: Calendar = .current,
        preset: HistoryPreset? = nil
    ) {
        startDate = calendar.dateInterval(of: .month, for: now)?.start ?? now
        endDate = now

        if let categoryID = preset?.categoryID {
            self.categoryID = categoryID
        }
        if let interval = preset?.interval {
            includesStartDate = true
            startDate = interval.start
            includesEndDate = true
            endDate = interval.end.addingTimeInterval(-1)
        }
    }

    var hasActiveFilters: Bool {
        kind != .all || accountID != nil || categoryID != nil
            || includesStartDate || includesEndDate
            || !minimumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !maximumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isValid: Bool {
        let minimumText = minimumAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumText = maximumAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !minimumText.isEmpty, minimumAmount == nil { return false }
        if !maximumText.isEmpty, maximumAmount == nil { return false }
        if let minimumAmount, minimumAmount < .zero { return false }
        if let maximumAmount, maximumAmount < .zero { return false }
        if let minimumAmount, let maximumAmount, minimumAmount > maximumAmount {
            return false
        }
        if includesStartDate, includesEndDate,
           FinancialPeriodBoundary.startOfDay(containing: startDate)
            > FinancialPeriodBoundary.startOfDay(containing: endDate) {
            return false
        }
        return true
    }

    private var minimumAmount: Decimal? {
        decimalAmount(from: minimumAmountText)
    }

    private var maximumAmount: Decimal? {
        decimalAmount(from: maximumAmountText)
    }

    func query(searchText: String, calendar: Calendar = .current) -> HistoryQuery {
        let start = includesStartDate
            ? FinancialPeriodBoundary.startOfDay(
                containing: startDate,
                calendar: calendar
            )
            : nil
        let end = includesEndDate
            ? FinancialPeriodBoundary.endOfDayExclusive(
                containing: endDate,
                calendar: calendar
            )
            : nil
        return HistoryQuery(
            searchText: searchText,
            kind: kind,
            accountID: accountID,
            categoryID: categoryID,
            startDate: start,
            endDateExclusive: end,
            minimumAmount: minimumAmount,
            maximumAmount: maximumAmount
        )
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
    @State private var appliedSearchText = ""
    @State private var filters: HistoryFilterDraft
    @State private var showingFilters = false
    @State private var selectedEntry: JournalEntry?
    @State private var entryPendingDeletion: JournalEntry?
    @State private var errorMessage: String?

    init(preset: HistoryPreset? = nil) {
        _filters = State(initialValue: HistoryFilterDraft(preset: preset))
    }

    private var filteredEntries: [JournalEntry] {
        filters.query(searchText: appliedSearchText)
            .filteredEntries(model.entries, accounts: model.accounts)
    }

    private var summary: HistorySummary {
        HistoryQuery().summary(for: filteredEntries, accounts: model.accounts)
    }

    private var dayGroups: [HistoryDayGroup] {
        Dictionary(grouping: filteredEntries) {
            Calendar.current.startOfDay(for: $0.occurredAt)
        }
        .map { HistoryDayGroup(date: $0.key, entries: $0.value) }
        .sorted { $0.date > $1.date }
    }

    private var unavailableTitle: LocalizedStringKey {
        model.entries.isEmpty && appliedSearchText.isEmpty && !filters.hasActiveFilters
            ? "history.empty" : "history.no_results"
    }

    private var unavailableDetail: LocalizedStringKey {
        model.entries.isEmpty && appliedSearchText.isEmpty && !filters.hasActiveFilters
            ? "history.empty_detail" : "history.no_results_detail"
    }

    var body: some View {
        NavigationStack {
            List {
                if filters.hasActiveFilters {
                    Section {
                        HStack {
                            Label(
                                "history.filters_active",
                                systemImage: "line.3.horizontal.decrease.circle.fill"
                            )
                            Spacer()
                            Button("action.reset") {
                                filters = HistoryFilterDraft()
                            }
                        }
                    }
                }

                Section {
                    HistorySummaryView(summary: summary)
                }

                if dayGroups.isEmpty {
                    if model.entries.isEmpty,
                       appliedSearchText.isEmpty,
                       !filters.hasActiveFilters {
                        VStack(spacing: 10) {
                            MoneyUpIllustration("MoneyUpMoneyWorld", role: .empty)
                            Text(unavailableTitle)
                                .font(.title2.bold())
                            Text(unavailableDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .listRowBackground(Color.clear)
                    } else {
                        ContentUnavailableView(
                            unavailableTitle,
                            systemImage: "clock.arrow.circlepath",
                            description: Text(unavailableDetail)
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
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
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("tab.history")
            .searchable(text: $searchText, prompt: "history.search")
            .task(id: searchText) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    appliedSearchText = searchText
                } catch {
                    // A newer keystroke superseded this search.
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingFilters = true
                    } label: {
                        Image(
                            systemName: filters.hasActiveFilters
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                    .accessibilityLabel("history.filter")
                }
            }
            .sheet(isPresented: $showingFilters) {
                HistoryFilterSheet(
                    filters: filters,
                    accounts: model.accounts.filter {
                        $0.kind == .asset || $0.kind == .liability
                    },
                    categories: model.accounts.filter {
                        $0.kind == .expense || $0.kind == .income
                    }
                ) { filters = $0 }
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

    private func delete(_ entry: JournalEntry) async {
        do {
            try await model.deleteEntry(id: entry.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HistorySummaryView: View {
    let summary: HistorySummary

    private var currencies: [CurrencyCode] {
        summary.amountsByCurrency.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("history.transactions") {
                Text(summary.transactionCount, format: .number)
                    .monospacedDigit()
            }
            if currencies.isEmpty {
                Text("history.no_filtered_total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(currencies, id: \.self) { currency in
                    LabeledContent {
                        if let amount = summary.amountsByCurrency[currency] {
                            switch DerivedValue<Money>.money(
                                amount,
                                currency: currency,
                                operation: "history-filtered-total"
                            ) {
                            case let .available(money):
                                Text(formattedMoney(money))
                                    .monospacedDigit()
                            case let .unavailable(issue):
                                DerivedValueUnavailableView(issue: issue)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("history.filtered_total")
                            Text(currency.value)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("history.total_explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct HistoryFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HistoryFilterDraft

    let accounts: [LedgerAccount]
    let categories: [LedgerAccount]
    let onApply: (HistoryFilterDraft) -> Void

    init(
        filters: HistoryFilterDraft,
        accounts: [LedgerAccount],
        categories: [LedgerAccount],
        onApply: @escaping (HistoryFilterDraft) -> Void
    ) {
        _draft = State(initialValue: filters)
        self.accounts = accounts
        self.categories = categories
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("history.filter.kind", selection: $draft.kind) {
                        ForEach(HistoryKindFilter.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Picker("history.filter.account", selection: $draft.accountID) {
                        Text("history.filter.any_account").tag(nil as UUID?)
                        ForEach(accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    Picker("history.filter.category", selection: $draft.categoryID) {
                        Text("history.filter.any_category").tag(nil as UUID?)
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }

                Section("history.filter.date") {
                    Toggle("history.filter.start_date", isOn: $draft.includesStartDate)
                    if draft.includesStartDate {
                        DatePicker(
                            "history.filter.start_date",
                            selection: $draft.startDate,
                            displayedComponents: .date
                        )
                    }
                    Toggle("history.filter.end_date", isOn: $draft.includesEndDate)
                    if draft.includesEndDate {
                        DatePicker(
                            "history.filter.end_date",
                            selection: $draft.endDate,
                            displayedComponents: .date
                        )
                    }
                }

                Section {
                    TextField("history.filter.minimum", text: $draft.minimumAmountText)
                        .keyboardType(.decimalPad)
                    TextField("history.filter.maximum", text: $draft.maximumAmountText)
                        .keyboardType(.decimalPad)
                    if !draft.isValid {
                        Text("history.filter.invalid_range")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("history.filter.amount")
                } footer: {
                    Text("history.filter.amount_note")
                }

                Section {
                    Button("action.reset", role: .destructive) {
                        draft = HistoryFilterDraft()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("history.filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.apply") {
                        onApply(draft)
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
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
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
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
