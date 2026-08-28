import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UIKit

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

private struct HistoryFilterDraft: Hashable {
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
        calendar: Calendar = Calendar(identifier: .gregorian),
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

    func isValid(calendar: Calendar) -> Bool {
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
           FinancialPeriodBoundary.startOfDay(containing: startDate, calendar: calendar)
            > FinancialPeriodBoundary.startOfDay(containing: endDate, calendar: calendar) {
            return false
        }
        return true
    }

    mutating func rebaseInactiveDates(
        now: Date = Date(),
        calendar: Calendar
    ) {
        if !includesStartDate {
            startDate = calendar.dateInterval(of: .month, for: now)?.start ?? now
        }
        if !includesEndDate { endDate = now }
    }

    private var minimumAmount: Decimal? {
        decimalAmount(from: minimumAmountText)
    }

    private var maximumAmount: Decimal? {
        decimalAmount(from: maximumAmountText)
    }

    func query(
        searchText: String,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> HistoryQuery {
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

private struct HistoryLoadIdentifier: Equatable {
    let searchText: String
    let filters: HistoryFilterDraft
    let refreshGeneration: Int
}

private struct HistoryDayGroup: Identifiable {
    let date: Date
    let entries: [JournalEntry]
    var id: Date { date }
}

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var appliedSearchText = ""
    @State private var filters: HistoryFilterDraft
    @State private var showingFilters = false
    @State private var selectedEntry: JournalEntry?
    @State private var entryPendingDeletion: JournalEntry?
    @State private var errorMessage: String?
    @State private var loadedEntries: [JournalEntry] = []
    @State private var summary: HistorySummary?
    @State private var nextCursor: JournalEntryPageCursor?
    @State private var isLoadingPage = false
    @State private var refreshGeneration = 0
    @State private var didInitializeReportingDates = false
    private let showsChartReturn: Bool

    init(preset: HistoryPreset? = nil) {
        showsChartReturn = preset != nil
        _filters = State(initialValue: HistoryFilterDraft(preset: preset))
    }

    private var query: HistoryQuery {
        filters.query(
            searchText: appliedSearchText,
            calendar: model.reportingCalendar
        )
    }

    private var loadIdentifier: HistoryLoadIdentifier {
        HistoryLoadIdentifier(
            searchText: appliedSearchText,
            filters: filters,
            refreshGeneration: refreshGeneration
        )
    }

    private var dayGroups: [HistoryDayGroup] {
        Dictionary(grouping: loadedEntries) {
            let calendar = model.reportingCalendar
            return calendar.startOfDay(
                for: $0.originContext.attributedDate(in: calendar) ?? $0.occurredAt
            )
        }
        .map { HistoryDayGroup(date: $0.key, entries: $0.value) }
        .sorted { $0.date > $1.date }
    }

    private var unavailableTitle: LocalizedStringKey {
        !model.hasJournalEntries && appliedSearchText.isEmpty && !filters.hasActiveFilters
            ? "history.empty" : "history.no_results"
    }

    private var unavailableDetail: LocalizedStringKey {
        !model.hasJournalEntries && appliedSearchText.isEmpty && !filters.hasActiveFilters
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
                                filters = HistoryFilterDraft(
                                    calendar: model.reportingCalendar
                                )
                            }
                        }
                    }
                }

                Section {
                    if let summary {
                        HistorySummaryView(summary: summary)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("history.loading_summary")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if dayGroups.isEmpty {
                    if isLoadingPage {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.large)
                                .accessibilityLabel("history.loading")
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else if !model.hasJournalEntries,
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
                                .onAppear {
                                    guard entry.id == loadedEntries.last?.id else { return }
                                    Task { await loadNextPage() }
                                }
                                .swipeActions(edge: .trailing) {
                                    if !model.isProtectedJournalEntry(entry) {
                                        Button(role: .destructive) {
                                            entryPendingDeletion = entry
                                        } label: {
                                            Label("action.delete", systemImage: "trash")
                                        }
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
            .onAppear {
                guard !didInitializeReportingDates else { return }
                didInitializeReportingDates = true
                filters.rebaseInactiveDates(calendar: model.reportingCalendar)
            }
            .task(id: searchText) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    appliedSearchText = searchText
                } catch {
                    // A newer keystroke superseded this search.
                }
            }
            .task(id: loadIdentifier) {
                await reloadHistory()
            }
            .toolbar {
                if showsChartReturn {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Label(
                                "insights.back_to_chart",
                                systemImage: "chevron.backward"
                            )
                        }
                    }
                }
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
                    },
                    calendar: model.reportingCalendar
                ) { filters = $0 }
            }
            .sheet(item: $selectedEntry, onDismiss: {
                refreshGeneration &+= 1
            }) { entry in
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
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private func delete(_ entry: JournalEntry) async {
        do {
            try await model.deleteEntry(id: entry.id)
            refreshGeneration &+= 1
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    @MainActor
    private func reloadHistory() async {
        let expectedIdentifier = loadIdentifier
        let querySnapshot = query
        loadedEntries = []
        nextCursor = nil
        summary = nil
        isLoadingPage = true

        do {
            let firstPage = try await model.historyPage(query: querySnapshot)
            try Task.checkCancellation()
            guard loadIdentifier == expectedIdentifier else { return }
            loadedEntries = firstPage.entries
            nextCursor = firstPage.nextCursor
            isLoadingPage = false

            let resolvedSummary = try await model.historySummary(query: querySnapshot)
            try Task.checkCancellation()
            guard loadIdentifier == expectedIdentifier else { return }
            summary = resolvedSummary
        } catch is CancellationError {
            if loadIdentifier == expectedIdentifier { isLoadingPage = false }
        } catch {
            if loadIdentifier == expectedIdentifier {
                isLoadingPage = false
                errorMessage = safeUserMessage(for: error, context: .read)
            }
        }
    }

    @MainActor
    private func loadNextPage() async {
        guard !isLoadingPage, let cursor = nextCursor else { return }
        let expectedIdentifier = loadIdentifier
        let querySnapshot = query
        isLoadingPage = true
        do {
            let page = try await model.historyPage(
                query: querySnapshot,
                after: cursor
            )
            try Task.checkCancellation()
            guard loadIdentifier == expectedIdentifier else { return }
            let knownIDs = Set(loadedEntries.map(\.id))
            loadedEntries.append(contentsOf: page.entries.filter {
                !knownIDs.contains($0.id)
            })
            nextCursor = page.nextCursor
            isLoadingPage = false
        } catch is CancellationError {
            if loadIdentifier == expectedIdentifier { isLoadingPage = false }
        } catch {
            if loadIdentifier == expectedIdentifier {
                isLoadingPage = false
                errorMessage = safeUserMessage(for: error, context: .read)
            }
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
    let calendar: Calendar
    let onApply: (HistoryFilterDraft) -> Void

    private var selectedCurrency: CurrencyCode? {
        accounts.first(where: { $0.id == draft.accountID })?.currency
    }

    init(
        filters: HistoryFilterDraft,
        accounts: [LedgerAccount],
        categories: [LedgerAccount],
        calendar: Calendar,
        onApply: @escaping (HistoryFilterDraft) -> Void
    ) {
        _draft = State(initialValue: filters)
        self.accounts = accounts
        self.categories = categories
        self.calendar = calendar
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
                        .moneyAmountKeyboard(currency: selectedCurrency)
                    TextField("history.filter.maximum", text: $draft.maximumAmountText)
                        .moneyAmountKeyboard(currency: selectedCurrency)
                    if !draft.isValid(calendar: calendar) {
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
                        draft = HistoryFilterDraft(calendar: calendar)
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
                    .disabled(!draft.isValid(calendar: calendar))
                }
                MoneyUpKeyboardDoneToolbar()
            }
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }
}

private struct EditableEntryValues {
    let kind: QuickLogKind
    let amount: Decimal
    let destinationAmount: Decimal?
    let accountID: UUID
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let splitLines: [QuickLogSplitDraftLine]

    init?(entry: JournalEntry, accounts: [LedgerAccount]) {
        let userIDs = Set(accounts.filter {
            $0.kind == .asset || $0.kind == .liability
        }.map(\.id))
        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        let incomeIDs = Set(accounts.filter { $0.kind == .income }.map(\.id))

        switch entry.kind {
        case .expense:
            let categories = entry.postings.filter { expenseIDs.contains($0.accountID) }
            guard let category = categories.first, let account = entry.postings.first(where: {
                userIDs.contains($0.accountID)
            }), let combinedAmount = try? Self.total(of: categories) else { return nil }
            kind = category.money.amount < .zero ? .refund : .expense
            amount = combinedAmount
            destinationAmount = nil
            accountID = account.accountID
            destinationAccountID = nil
            categoryID = category.accountID
            splitLines = categories.count > 1 ? categories.map {
                QuickLogSplitDraftLine(
                    id: $0.id,
                    categoryID: $0.accountID,
                    amountText: editableAmount(abs($0.money.amount)),
                    memo: $0.memo ?? ""
                )
            } : []
        case .income:
            let categories = entry.postings.filter { incomeIDs.contains($0.accountID) }
            guard let category = categories.first, let account = entry.postings.first(where: {
                userIDs.contains($0.accountID)
            }), let combinedAmount = try? Self.total(of: categories) else { return nil }
            kind = .income
            amount = combinedAmount
            destinationAmount = nil
            accountID = account.accountID
            destinationAccountID = nil
            categoryID = category.accountID
            splitLines = categories.count > 1 ? categories.map {
                QuickLogSplitDraftLine(
                    id: $0.id,
                    categoryID: $0.accountID,
                    amountText: editableAmount(abs($0.money.amount)),
                    memo: $0.memo ?? ""
                )
            } : []
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
            splitLines = []
        case .adjustment, .investment:
            return nil
        }
    }

    private static func total(of postings: [Posting]) throws -> Decimal {
        var result = Decimal.zero
        for posting in postings {
            result = try CheckedDecimal.adding(
                result,
                abs(posting.money.amount)
            )
        }
        return result
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
    @State private var splitLines: [QuickLogSplitDraftLine]
    @State private var isSplitTransaction: Bool
    @State private var occurredAt: Date
    @State private var payee: String
    @State private var note: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false
    @State private var pendingAttachmentDeletionID: UUID?
    @State private var isConfirmingAttachmentDelete = false
    @State private var attachmentImages: [UUID: UIImage] = [:]
    @State private var attachmentLoadFailures = Set<UUID>()

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
        _splitLines = State(initialValue: [])
        _isSplitTransaction = State(
            initialValue: (entry.kind == .expense || entry.kind == .income)
                && entry.postings.count > 2
        )
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

    private var splitRemainder: Decimal? {
        guard let amount = decimalAmount(from: amountText),
              amount > .zero,
              let currency = sourceCurrency,
              let total = try? Money(amount, currency: currency),
              let lines = try? transactionSplitLines(currency: currency),
              let remainder = try? TransactionSplitCalculator.remainder(
                total: total,
                lines: lines
              ) else { return nil }
        return remainder.amount
    }

    private var splitLinesAreValid: Bool {
        guard isSplitTransaction,
              let amount = decimalAmount(from: amountText),
              let currency = sourceCurrency,
              let total = try? Money(amount, currency: currency),
              let lines = try? transactionSplitLines(currency: currency),
              lines.allSatisfy({ line in
                  categories.contains(where: {
                      $0.id == line.categoryAccountID
                  }) && currency.supports(line.amount.amount)
              }) else { return false }
        do {
            try TransactionSplitCalculator.validate(total: total, lines: lines)
            return true
        } catch {
            return false
        }
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
        if isSplitTransaction { return splitLinesAreValid }
        return categories.contains { $0.id == categoryID }
    }

    private var attachmentMetadata: [ReceiptAttachmentMetadata] {
        model.receiptAttachmentMetadata.filter { $0.entryID == entry.id }
    }

    @ViewBuilder
    private var splitEditor: some View {
        ForEach(splitLines.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "quick_log.split_category",
                    selection: Binding(
                        get: { splitLines[index].categoryID },
                        set: { splitLines[index].categoryID = $0 }
                    )
                ) {
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }

                HStack {
                    TextField(
                        "quick_log.split_amount",
                        text: Binding(
                            get: { splitLines[index].amountText },
                            set: { splitLines[index].amountText = $0 }
                        )
                    )
                    .moneyAmountKeyboard(currency: sourceCurrency)
                    .accessibilityLabel("quick_log.split_amount")
                    if let sourceCurrency {
                        Text(sourceCurrency.value).foregroundStyle(.secondary)
                    }
                    if splitLines.count > 2 {
                        Button(role: .destructive) {
                            splitLines.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .accessibilityLabel("quick_log.split_remove")
                    }
                }

                TextField(
                    "quick_log.split_memo",
                    text: Binding(
                        get: { splitLines[index].memo },
                        set: { splitLines[index].memo = $0 }
                    )
                )
                .font(.caption)
            }
            .padding(.vertical, 4)
        }

        Button {
            splitLines.append(
                QuickLogSplitDraftLine(categoryID: categoryID ?? categories.first?.id)
            )
        } label: {
            Label("quick_log.split_add", systemImage: "plus.circle")
        }

        if let remainder = splitRemainder, let sourceCurrency {
            LabeledContent("quick_log.split_remainder") {
                Text("\(editableAmount(remainder)) \(sourceCurrency.value)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(remainder == .zero ? Color.green : Color.red)
            }
            .accessibilityHint(
                remainder == .zero
                    ? Text("quick_log.split_balanced")
                    : Text("quick_log.split_not_balanced")
            )
        }
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
                                .moneyAmountKeyboard(currency: sourceCurrency)
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
                                    .moneyAmountKeyboard(currency: destinationCurrency)
                                    if let destinationCurrency {
                                        Text(destinationCurrency.value)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            Toggle(
                                "quick_log.split_transaction",
                                isOn: Binding(
                                    get: { isSplitTransaction },
                                    set: { enabled in
                                        isSplitTransaction = enabled
                                        if enabled, splitLines.count < 2 {
                                            let initialCategory = categoryID ?? categories.first?.id
                                            splitLines = [
                                                QuickLogSplitDraftLine(categoryID: initialCategory),
                                                QuickLogSplitDraftLine(categoryID: initialCategory)
                                            ]
                                        } else if !enabled {
                                            splitLines = []
                                        }
                                    }
                                )
                            )
                            .accessibilityHint("quick_log.split_not_balanced")

                            if isSplitTransaction {
                                splitEditor
                            } else {
                                Picker("transaction.category", selection: $categoryID) {
                                    ForEach(categories) { category in
                                        Text(category.name).tag(Optional(category.id))
                                    }
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

                if !model.isProtectedJournalEntry(entry) {
                    Section {
                        Button("action.delete", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }

                if let revisedAt = entry.revisedAt {
                    Section {
                        LabeledContent("history.last_edited") {
                            Text(revisedAt, format: .dateTime.month().day().year().hour().minute())
                        }
                    }
                }


                if !attachmentMetadata.isEmpty {
                    Section {
                        ForEach(attachmentMetadata) { attachment in
                            VStack(alignment: .leading, spacing: 8) {
                                if let image = attachmentImages[attachment.id] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .accessibilityLabel("receipt.attachment_image")
                                } else if attachmentLoadFailures.contains(attachment.id) {
                                    Button("action.retry") {
                                        attachmentLoadFailures.remove(attachment.id)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 88)
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 88)
                                        .task(id: attachment.id) {
                                            await loadAttachmentImage(attachment.id)
                                        }
                                }
                                Button("receipt.delete_attachment", role: .destructive) {
                                    pendingAttachmentDeletionID = attachment.id
                                    isConfirmingAttachmentDelete = true
                                }
                                .accessibilityHint("receipt.delete_attachment_hint")
                            }
                        }
                    } header: {
                        Text("receipt.attachments")
                    } footer: {
                        Text("receipt.attachment_encrypted_detail")
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
                MoneyUpKeyboardDoneToolbar()
            }
            .task { loadValues() }
            .onChange(of: model.state) { _, state in
                if state != .ready {
                    attachmentImages.removeAll()
                    attachmentLoadFailures.removeAll()
                }
            }
            .onChange(of: kind) { _, newKind in
                if newKind == .transfer {
                    isSplitTransaction = false
                    splitLines = []
                }
                selectValidDefaults()
            }
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
            .confirmationDialog(
                "receipt.delete_title",
                isPresented: $isConfirmingAttachmentDelete,
                titleVisibility: .visible
            ) {
                Button("receipt.delete_attachment", role: .destructive) {
                    guard let id = pendingAttachmentDeletionID else { return }
                    Task { await deleteAttachment(id) }
                }
                Button("action.cancel", role: .cancel) {
                    pendingAttachmentDeletionID = nil
                }
            } message: {
                Text("receipt.delete_detail")
            }
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
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
        splitLines = values.splitLines
        isSplitTransaction = values.splitLines.count >= 2
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
        if isSplitTransaction {
            for index in splitLines.indices where !categories.contains(
                where: { $0.id == splitLines[index].categoryID }
            ) {
                splitLines[index].categoryID = categories.first?.id
            }
        }
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText),
              let accountID else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let revisedSplits = try splitTransactionLines()
            try await model.replaceEntry(
                id: entry.id,
                kind: kind,
                amount: amount,
                destinationAmount: decimalAmount(from: destinationAmountText),
                accountID: accountID,
                destinationAccountID: destinationAccountID,
                categoryID: categoryID,
                splitLines: revisedSplits,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func splitTransactionLines() throws -> [TransactionSplitLine]? {
        guard isSplitTransaction, kind != .transfer else { return nil }
        guard let currency = sourceCurrency else { throw AppModelError.accountHasNoCurrency }
        guard let amount = decimalAmount(from: amountText) else {
            throw AppModelError.missingRecord
        }
        let lines = try transactionSplitLines(currency: currency)
        try TransactionSplitCalculator.validate(
            total: Money(amount, currency: currency),
            lines: lines
        )
        return lines
    }

    private func transactionSplitLines(
        currency: CurrencyCode
    ) throws -> [TransactionSplitLine] {
        try splitLines.map { line in
            guard let categoryID = line.categoryID,
                  let amount = decimalAmount(from: line.amountText) else {
                throw AppModelError.missingRecord
            }
            return TransactionSplitLine(
                id: line.id,
                categoryAccountID: categoryID,
                amount: try Money(amount, currency: currency),
                memo: line.memo
            )
        }
    }

    private func delete() async {
        do {
            try await model.deleteEntry(id: entry.id)
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func deleteAttachment(_ id: UUID) async {
        do {
            try await model.deleteReceiptAttachment(id: id)
            attachmentImages[id] = nil
            attachmentLoadFailures.remove(id)
            pendingAttachmentDeletionID = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func loadAttachmentImage(_ id: UUID) async {
        guard attachmentImages[id] == nil else { return }
        do {
            let attachment = try await model.receiptAttachment(id: id)
            try Task.checkCancellation()
            guard let image = UIImage(data: attachment.data) else {
                throw ReceiptAttachmentError.emptyData
            }
            attachmentImages[id] = image
            attachmentLoadFailures.remove(id)
        } catch is CancellationError {
            return
        } catch {
            attachmentLoadFailures.insert(id)
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }
}
