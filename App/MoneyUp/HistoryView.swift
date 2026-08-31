import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UIKit

struct HistoryPreset: Equatable {
    let categoryIDs: Set<UUID>?
    let categoryPostingCurrency: CurrencyCode?
    let interval: DateInterval?

    init(
        categoryID: UUID? = nil,
        categoryIDs: Set<UUID>? = nil,
        categoryPostingCurrency: CurrencyCode? = nil,
        interval: DateInterval? = nil
    ) {
        self.categoryIDs = categoryIDs ?? categoryID.map { Set([$0]) }
        self.categoryPostingCurrency = categoryPostingCurrency
        self.interval = interval
    }
}

extension HistoryKindFilter {
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

struct HistoryFilterDraft: Hashable {
    var kind: HistoryKindFilter = .all
    var accountID: UUID?
    var categoryIDs: Set<UUID>?
    var categoryPostingCurrency: CurrencyCode?
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

        categoryIDs = preset?.categoryIDs
        categoryPostingCurrency = preset?.categoryPostingCurrency
        if let interval = preset?.interval {
            includesStartDate = true
            startDate = interval.start
            includesEndDate = true
            endDate = interval.end.addingTimeInterval(-1)
        }
    }

    var hasActiveFilters: Bool {
        kind != .all || accountID != nil || categoryIDs != nil
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
            categoryIDs: categoryIDs,
            categoryPostingCurrency: categoryPostingCurrency,
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
    private enum InitialPageOutcome: Sendable {
        case available(AppModel.HistoryPageResult)
        case unavailable(String)
        case cancelled
    }

    private enum SummaryOutcome: Sendable {
        case available(HistorySummary)
        case unavailable(String)
        case cancelled
    }

    @Environment(AppModel.self) private var model
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
    @State private var initialPageErrorMessage: String?
    @State private var summaryErrorMessage: String?
    @State private var paginationErrorMessage: String?
    @State private var refreshGeneration = 0
    @State private var didInitializeReportingDates = false
    init(preset: HistoryPreset? = nil) {
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

                if !model.journalRecentEntriesAreCurrent {
                    Section {
                        DerivedValueUnavailableView(issue: .appNotReady)
                            .padding(.vertical, 8)
                        Button("action.retry") {
                            model.retryUnavailableJournalProjection()
                        }
                    }
                } else {
                    Section {
                        if let summary {
                            HistorySummaryView(summary: summary)
                        } else if let summaryErrorMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(
                                    "history.summary_unavailable",
                                    systemImage: "exclamationmark.circle"
                                )
                                .font(.subheadline.weight(.semibold))
                                Text(summaryErrorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("action.retry") {
                                    refreshGeneration &+= 1
                                }
                            }
                            .accessibilityElement(children: .contain)
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
                        if let initialPageErrorMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(
                                    "history.entries_unavailable",
                                    systemImage: "exclamationmark.circle"
                                )
                                .font(.headline)
                                Text(initialPageErrorMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("action.retry") {
                                    refreshGeneration &+= 1
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if isLoadingPage {
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

                        if isLoadingPage {
                            Section {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("history.loading")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityElement(children: .combine)
                            }
                        } else if let paginationErrorMessage {
                            Section {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label(
                                        "history.page_unavailable",
                                        systemImage: "exclamationmark.circle"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    Text(paginationErrorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("action.retry") {
                                        Task { await loadNextPage() }
                                    }
                                }
                            }
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
            .onChange(of: model.journalRecentEntriesAreCurrent) { _, isCurrent in
                loadedEntries = []
                nextCursor = nil
                summary = nil
                isLoadingPage = false
                initialPageErrorMessage = nil
                summaryErrorMessage = nil
                paginationErrorMessage = nil
                if isCurrent { refreshGeneration &+= 1 }
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
                        ($0.kind == .asset || $0.kind == .liability)
                            && $0.systemRole == nil
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
        guard model.journalRecentEntriesAreCurrent else {
            loadedEntries = []
            nextCursor = nil
            summary = nil
            isLoadingPage = false
            initialPageErrorMessage = nil
            summaryErrorMessage = nil
            paginationErrorMessage = nil
            return
        }
        let expectedIdentifier = loadIdentifier
        let querySnapshot = query
        loadedEntries = []
        nextCursor = nil
        summary = nil
        initialPageErrorMessage = nil
        summaryErrorMessage = nil
        paginationErrorMessage = nil
        isLoadingPage = true

        async let pageOutcome = initialPageOutcome(query: querySnapshot)
        async let totalsOutcome = summaryOutcome(query: querySnapshot)
        let resolvedPage = await pageOutcome

        guard !Task.isCancelled,
              loadIdentifier == expectedIdentifier else { return }
        isLoadingPage = false

        switch resolvedPage {
        case let .available(page):
            loadedEntries = page.entries
            nextCursor = page.nextCursor
        case let .unavailable(message):
            initialPageErrorMessage = message
        case .cancelled:
            return
        }

        let resolvedSummary = await totalsOutcome
        guard !Task.isCancelled,
              loadIdentifier == expectedIdentifier else { return }
        switch resolvedSummary {
        case let .available(resolvedSummary):
            summary = resolvedSummary
        case let .unavailable(message):
            summaryErrorMessage = message
        case .cancelled:
            return
        }
    }

    @MainActor
    private func initialPageOutcome(query: HistoryQuery) async -> InitialPageOutcome {
        do {
            return .available(try await model.historyPage(query: query))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unavailable(safeUserMessage(for: error, context: .read))
        }
    }

    @MainActor
    private func summaryOutcome(query: HistoryQuery) async -> SummaryOutcome {
        do {
            return .available(try await model.historySummary(query: query))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unavailable(safeUserMessage(for: error, context: .read))
        }
    }

    @MainActor
    private func loadNextPage() async {
        guard !isLoadingPage, let cursor = nextCursor else { return }
        let expectedIdentifier = loadIdentifier
        let querySnapshot = query
        isLoadingPage = true
        paginationErrorMessage = nil
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
                paginationErrorMessage = safeUserMessage(for: error, context: .read)
            }
        }
    }
}
