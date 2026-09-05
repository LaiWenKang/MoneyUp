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
        kind != .all || accountID != nil || categoryIDs != nil || categoryPostingCurrency != nil
            || includesStartDate || includesEndDate
            || !minimumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !maximumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Date shortcuts own only the date predicates. Every other advanced
    /// predicate remains active and must keep the filter indicator visible.
    var hasNonDateAdvancedFilters: Bool {
        kind != .all || accountID != nil || categoryPostingCurrency != nil
            || !minimumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !maximumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func showsAdvancedFilterIndicator(quickRange: HistoryQuickRange?) -> Bool {
        categoryIDs != nil
            || hasNonDateAdvancedFilters
            || (quickRange == nil && (includesStartDate || includesEndDate))
    }

    func isValid(calendar: Calendar) -> Bool {
        hasValidAmountRange && hasValidDateRange(calendar: calendar)
    }

    var hasValidAmountRange: Bool {
        let minimumText = minimumAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumText = maximumAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !minimumText.isEmpty, minimumAmount == nil { return false }
        if !maximumText.isEmpty, maximumAmount == nil { return false }
        if let minimumAmount, minimumAmount < .zero { return false }
        if let maximumAmount, maximumAmount < .zero { return false }
        if let minimumAmount, let maximumAmount, minimumAmount > maximumAmount {
            return false
        }
        return true
    }

    func hasValidDateRange(calendar: Calendar) -> Bool {
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
    let logicalBookRevision: UInt64
}

private struct HistoryPerformanceMeasurement {
    let id: UUID
    let loadIdentifier: HistoryLoadIdentifier
    let interval: MoneyUpPerformanceInterval?
}

private struct HistoryDayGroup: Identifiable {
    let date: Date
    let entries: [JournalEntry]
    var id: Date { date }
}

struct HistoryHotCategory: Equatable, Identifiable {
    let id: UUID
    let occurrenceCount: Int
    let mostRecentOccurrence: Date
}

/// Ranks categories from the bounded recent-activity cache, not feature-shaped
/// filters that are often empty. Frequency leads; recency and UUID provide
/// stable deterministic tie-breaks. One split entry counts once per category.
enum HistoryHotCategoryRanker {
    static func ranked(
        entries: some Sequence<JournalEntry>,
        accounts: some Sequence<LedgerAccount>,
        limit: Int = 5
    ) -> [HistoryHotCategory] {
        guard limit > 0 else { return [] }
        let eligibleIDs = Set(accounts.lazy.filter {
            !$0.isArchived
                && $0.systemRole == nil
                && ($0.kind == .expense || $0.kind == .income)
        }.map(\.id))
        var counts: [UUID: Int] = [:]
        var recency: [UUID: Date] = [:]

        for entry in entries {
            let categoryIDs = Set(entry.postings.lazy.compactMap { posting in
                eligibleIDs.contains(posting.accountID) ? posting.accountID : nil
            })
            for categoryID in categoryIDs {
                counts[categoryID, default: 0] += 1
                recency[categoryID] = max(
                    recency[categoryID] ?? .distantPast,
                    entry.occurredAt
                )
            }
        }

        return counts.map { categoryID, count in
            HistoryHotCategory(
                id: categoryID,
                occurrenceCount: count,
                mostRecentOccurrence: recency[categoryID] ?? .distantPast
            )
        }
        .sorted { lhs, rhs in
            if lhs.occurrenceCount != rhs.occurrenceCount {
                return lhs.occurrenceCount > rhs.occurrenceCount
            }
            if lhs.mostRecentOccurrence != rhs.mostRecentOccurrence {
                return lhs.mostRecentOccurrence > rhs.mostRecentOccurrence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(limit)
        .map { $0 }
    }
}

enum HistoryCategoryFilterState: Equatable {
    case all
    case category(UUID)
    case group(Int)

    init(categoryIDs: Set<UUID>?) {
        guard let categoryIDs else {
            self = .all
            return
        }
        if categoryIDs.count == 1, let categoryID = categoryIDs.first {
            self = .category(categoryID)
        } else {
            self = .group(categoryIDs.count)
        }
    }
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
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @Environment(\.appReportingSnapshot) private var sharedReportingSnapshot
    @AppStorage(MoneyAmountPrivacy.storageKey)
    private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var searchText = ""
    @State private var appliedSearchText = ""
    @State private var filters: HistoryFilterDraft
    @State private var showingFilters = false
    @State private var selectedEntry: JournalEntry?
    @State private var entryPendingDeletion: JournalEntry?
    @State private var errorMessage: String?
    @State private var loadedEntries: [JournalEntry] = []
    @State private var attachmentMatchesByEntryID:
        [UUID: ReceiptAttachmentSearchMatch] = [:]
    @State private var summary: HistorySummary?
    @State private var nextCursor: JournalEntryPageCursor?
    @State private var isLoadingPage = false
    @State private var initialPageErrorMessage: String?
    @State private var summaryErrorMessage: String?
    @State private var paginationErrorMessage: String?
    @State private var refreshGeneration = 0
    @State private var didInitializeReportingDates = false
    @State private var isInitialHistoryLoadInProgress = false
    @State private var pendingPaginationAfterInitialLoad = false
    @State private var initialHistoryPerformanceMeasurement:
        HistoryPerformanceMeasurement?
    @State private var paginationPerformanceMeasurement:
        HistoryPerformanceMeasurement?
    @State private var quickRange: HistoryQuickRange?
    @State private var lastAppliedRollingDay: ReportingDayIdentity?
    let returnOrigin: HistoryReturnOrigin?
    let onReturnToOrigin: @MainActor () -> Void

    init(
        preset: HistoryPreset? = nil,
        returnOrigin: HistoryReturnOrigin? = nil,
        onReturnToOrigin: @escaping @MainActor () -> Void = {}
    ) {
        _filters = State(initialValue: HistoryFilterDraft(preset: preset))
        _quickRange = State(initialValue: preset == nil ? .today : nil)
        self.returnOrigin = returnOrigin
        self.onReturnToOrigin = onReturnToOrigin
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
            refreshGeneration: refreshGeneration,
            logicalBookRevision: model.logicalBookRevision
        )
    }

    private var hasAdvancedFilters: Bool {
        filters.showsAdvancedFilterIndicator(quickRange: quickRange)
    }

    private var hotCategories: [HistoryHotCategory] {
        HistoryHotCategoryRanker.ranked(
            entries: model.entries,
            accounts: model.accounts
        )
    }

    private var categoryFilterValue: String {
        switch HistoryCategoryFilterState(categoryIDs: filters.categoryIDs) {
        case .all:
            AppLocalization.string("history.filter.any_category")
        case let .category(categoryID):
            model.categoryPathName(for: categoryID)
        case let .group(count):
            String(
                format: AppLocalization.string("history.filter.category_count"),
                count
            )
        }
    }

    private var reportingSnapshot: AppReportingSnapshot {
        sharedReportingSnapshot
            ?? AppReportingSnapshot(
                instant: model.currentDateForUserAction(),
                calendar: model.reportingCalendar
            )
    }

    private var reportingDayIdentity: ReportingDayIdentity {
        reportingSnapshot.reportingDayIdentity
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
        let _ = hidesAmounts
        return List {
            Section {
                HistoryScopeSelector(selection: $quickRange)
            }
            .listRowBackground(Color.clear)

            Section {
                HStack(spacing: 8) {
                    Menu {
                        Button {
                            setCategoryFilter(nil)
                        } label: {
                            Label(
                                "history.filter.any_category",
                                systemImage: filters.categoryIDs == nil
                                    ? "checkmark"
                                    : "square.grid.2x2"
                            )
                        }

                        if !hotCategories.isEmpty {
                            Section("history.hot_categories") {
                                ForEach(hotCategories) { hotCategory in
                                    let selectedIDs = Set([hotCategory.id])
                                    Button {
                                        setCategoryFilter(selectedIDs)
                                    } label: {
                                        Label(
                                            model.categoryPathName(for: hotCategory.id),
                                            systemImage: filters.categoryIDs == selectedIDs
                                                ? "checkmark"
                                                : "clock.arrow.circlepath"
                                        )
                                    }
                                }
                            }
                        }

                        Divider()
                        Button {
                            showingFilters = true
                        } label: {
                            Label(
                                "history.filter.more_categories",
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("history.filter.category")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(categoryFilterValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("history.filter.category")
                    .accessibilityValue(categoryFilterValue)
                    .accessibilityHint("history.filter.category_hint")

                    if filters.categoryIDs != nil {
                        Button {
                            setCategoryFilter(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("history.filter.clear_category")
                    }
                }
            }

            Section {
                HStack(spacing: 12) {
                    Button { showingFilters = true } label: {
                        Label {
                            Text(filters.activeFilterCount == 0
                                ? AppLocalization.string("history.filter")
                                : String(format: AppLocalization.string("history.filter_count"), filters.activeFilterCount))
                        } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    }
                    .labelStyle(.titleAndIcon)
                    Spacer(minLength: 8)
                    Button("history.clear_filters") {
                        let snapshot = reportingSnapshot
                        filters = HistoryFilterDraft(now: snapshot.instant, calendar: snapshot.calendar)
                        quickRange = .all
                    }.disabled(!filters.hasActiveFilters)
                }
                if !searchText.isEmpty {
                    Button("history.clear_search") { searchText = ""; appliedSearchText = "" }
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
                        } else if isInitialHistoryLoadInProgress {
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
                                        TransactionRow(
                                            entry: entry,
                                            searchMatchLabel: attachmentMatchLabel(
                                                attachmentMatchesByEntryID[entry.id]
                                            )
                                        )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .onAppear {
                                        guard entry.id == loadedEntries.last?.id else {
                                            return
                                        }
                                        requestNextPageWhenReady()
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
                let snapshot = reportingSnapshot
                if !didInitializeReportingDates {
                    didInitializeReportingDates = true
                    filters.rebaseInactiveDates(
                        now: snapshot.instant,
                        calendar: snapshot.calendar
                    )
                }
                refreshRollingQuickRangeIfNeeded(snapshot: snapshot)
            }
            .onChange(of: quickRange) { _, range in
                guard let range else {
                    lastAppliedRollingDay = nil
                    return
                }
                applyQuickRange(range, snapshot: reportingSnapshot)
            }
            .onChange(of: reportingDayIdentity) { _, _ in
                refreshRollingQuickRangeIfNeeded(snapshot: reportingSnapshot)
            }
            .task(id: searchText) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard appliedSearchText != searchText else { return }
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
                attachmentMatchesByEntryID = [:]
                nextCursor = nil
                summary = nil
                isLoadingPage = false
                initialPageErrorMessage = nil
                summaryErrorMessage = nil
                paginationErrorMessage = nil
                finishInitialHistoryMeasurement(outcome: .cancelled)
                finishPaginationMeasurement(outcome: .cancelled)
                isInitialHistoryLoadInProgress = false
                pendingPaginationAfterInitialLoad = false
                if isCurrent { refreshGeneration &+= 1 }
            }
            .onDisappear {
                finishInitialHistoryMeasurement(outcome: .cancelled)
                finishPaginationMeasurement(outcome: .cancelled)
            }
            .onChange(of: model.logicalBookRevision) { _, _ in
                loadedEntries = []
                attachmentMatchesByEntryID = [:]
                nextCursor = nil
                summary = nil
                isLoadingPage = false
                initialPageErrorMessage = nil
                summaryErrorMessage = nil
                paginationErrorMessage = nil
                selectedEntry = nil
                finishInitialHistoryMeasurement(outcome: .cancelled)
                finishPaginationMeasurement(outcome: .cancelled)
                isInitialHistoryLoadInProgress = false
                pendingPaginationAfterInitialLoad = false
            }
            .toolbar {
                if let returnOrigin {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onReturnToOrigin()
                        } label: {
                            Label(
                                returnOrigin.backTitle,
                                systemImage: "chevron.backward"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .accessibilityLabel(returnOrigin.backTitle)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    MoneyUpAmountPrivacyButton()

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
                ) { updatedFilters in
                    guard filters != updatedFilters else { return }
                    filters = updatedFilters
                    quickRange = nil
                }
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
            .moneyUpOperationErrorAlert(message: $errorMessage)
            .environment(\.calendar, model.reportingCalendar)
            .environment(\.timeZone, model.reportingCalendar.timeZone)
    }
}

extension HistoryView {
    private func setCategoryFilter(_ categoryIDs: Set<UUID>?) {
        withAnimation(
            MoneyUpMotion.animation(
                for: .selection,
                reduceMotion: reduceMotion
            )
        ) {
            filters.categoryIDs = categoryIDs
            filters.categoryPostingCurrency = nil
        }
    }

    private func refreshRollingQuickRangeIfNeeded(
        snapshot: AppReportingSnapshot
    ) {
        guard HistoryRollingRangeRefreshPolicy.shouldReapply(
            range: quickRange,
            lastAppliedDay: lastAppliedRollingDay,
            currentDay: snapshot.reportingDayIdentity
        ), let quickRange else { return }
        applyQuickRange(quickRange, snapshot: snapshot)
    }

    private func applyQuickRange(
        _ range: HistoryQuickRange,
        snapshot: AppReportingSnapshot
    ) {
        filters.applyQuickRange(
            range,
            asOf: snapshot.instant,
            calendar: snapshot.calendar
        )
        lastAppliedRollingDay = range.isRolling
            ? snapshot.reportingDayIdentity
            : nil
    }

    private func delete(_ entry: JournalEntry) async {
        do {
            try await model.deleteEntry(id: entry.id)
            refreshGeneration &+= 1
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func attachmentMatchLabel(
        _ match: ReceiptAttachmentSearchMatch?
    ) -> String? {
        guard let match else { return nil }
        let fallbackKey = match.mediaType == .pdf
            ? "evidence.pdf" : "evidence.photo"
        let name = match.displayName ?? AppLocalization.string(fallbackKey)
        return String(
            format: AppLocalization.string("history.found_in_attachment"),
            name
        )
    }

    @MainActor
    private func reloadHistory() async {
        guard model.journalRecentEntriesAreCurrent else {
            loadedEntries = []
            attachmentMatchesByEntryID = [:]
            nextCursor = nil
            summary = nil
            isLoadingPage = false
            isInitialHistoryLoadInProgress = false
            initialPageErrorMessage = nil
            summaryErrorMessage = nil
            paginationErrorMessage = nil
            return
        }
        let expectedIdentifier = loadIdentifier
        let performanceMeasurementID = beginInitialHistoryMeasurement(
            loadIdentifier: expectedIdentifier
        )
        var performanceOutcome = MoneyUpPerformanceOutcome.cancelled
        defer {
            finishInitialHistoryMeasurement(
                id: performanceMeasurementID,
                loadIdentifier: expectedIdentifier,
                outcome: performanceOutcome
            )
            completeInitialHistoryLoadIfCurrent(
                expectedIdentifier,
                outcome: performanceOutcome
            )
        }
        let querySnapshot = query
        loadedEntries = []
        attachmentMatchesByEntryID = [:]
        nextCursor = nil
        summary = nil
        initialPageErrorMessage = nil
        summaryErrorMessage = nil
        paginationErrorMessage = nil

        async let pageOutcome = initialPageOutcome(query: querySnapshot)
        async let totalsOutcome = summaryOutcome(query: querySnapshot)
        let resolvedPage = await pageOutcome

        guard model.journalRecentEntriesAreCurrent,
              !Task.isCancelled,
              loadIdentifier == expectedIdentifier else { return }
        var didFail = false

        switch resolvedPage {
        case let .available(page):
            loadedEntries = page.entries
            nextCursor = page.nextCursor
            attachmentMatchesByEntryID = page.attachmentMatchesByEntryID
        case let .unavailable(message):
            initialPageErrorMessage = message
            didFail = true
        case .cancelled:
            return
        }

        let resolvedSummary = await totalsOutcome
        guard model.journalRecentEntriesAreCurrent,
              !Task.isCancelled,
              loadIdentifier == expectedIdentifier else { return }
        switch resolvedSummary {
        case let .available(resolvedSummary):
            summary = resolvedSummary
        case let .unavailable(message):
            summaryErrorMessage = message
            didFail = true
        case .cancelled:
            return
        }
        // Both result states now belong to this exact load generation. The
        // interval ends at their SwiftUI state-publication boundary, not pixels.
        performanceOutcome = didFail ? .failure : .success
    }

    @MainActor
    private func beginInitialHistoryMeasurement(
        loadIdentifier: HistoryLoadIdentifier
    ) -> UUID {
        finishInitialHistoryMeasurement(outcome: .cancelled)
        finishPaginationMeasurement(outcome: .cancelled)
        let id = UUID()
        initialHistoryPerformanceMeasurement = HistoryPerformanceMeasurement(
            id: id,
            loadIdentifier: loadIdentifier,
            interval: MoneyUpPerformanceSignposts.begin(.historyQueryToContent)
        )
        isInitialHistoryLoadInProgress = true
        isLoadingPage = false
        pendingPaginationAfterInitialLoad = false
        return id
    }

    @MainActor
    private func finishInitialHistoryMeasurement(
        id: UUID? = nil,
        loadIdentifier: HistoryLoadIdentifier? = nil,
        outcome: MoneyUpPerformanceOutcome
    ) {
        guard let measurement = initialHistoryPerformanceMeasurement,
              id == nil || measurement.id == id,
              loadIdentifier == nil
                || measurement.loadIdentifier == loadIdentifier else { return }
        initialHistoryPerformanceMeasurement = nil
        MoneyUpPerformanceSignposts.end(
            measurement.interval,
            outcome: outcome
        )
    }

    @MainActor
    private func completeInitialHistoryLoadIfCurrent(
        _ expectedIdentifier: HistoryLoadIdentifier,
        outcome: MoneyUpPerformanceOutcome
    ) {
        guard loadIdentifier == expectedIdentifier else { return }
        isInitialHistoryLoadInProgress = false
        guard outcome != .cancelled,
              pendingPaginationAfterInitialLoad else { return }
        pendingPaginationAfterInitialLoad = false
        Task { await loadNextPage() }
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
        guard !isInitialHistoryLoadInProgress,
              !isLoadingPage,
              let cursor = nextCursor else { return }
        let expectedIdentifier = loadIdentifier
        let performanceMeasurementID = beginPaginationMeasurement(
            loadIdentifier: expectedIdentifier
        )
        var performanceOutcome = MoneyUpPerformanceOutcome.cancelled
        defer {
            finishPaginationMeasurement(
                id: performanceMeasurementID,
                loadIdentifier: expectedIdentifier,
                outcome: performanceOutcome
            )
        }
        let querySnapshot = query
        isLoadingPage = true
        paginationErrorMessage = nil
        do {
            let page = try await model.historyPage(
                query: querySnapshot,
                after: cursor
            )
            try Task.checkCancellation()
            guard model.journalRecentEntriesAreCurrent,
                  loadIdentifier == expectedIdentifier else { return }
            let knownIDs = Set(loadedEntries.map(\.id))
            loadedEntries.append(contentsOf: page.entries.filter {
                !knownIDs.contains($0.id)
            })
            attachmentMatchesByEntryID.merge(
                page.attachmentMatchesByEntryID,
                uniquingKeysWith: { current, _ in current }
            )
            nextCursor = page.nextCursor
            isLoadingPage = false
            // Appended rows and cursor now share one generation-owned state
            // publication. This later-page name is distinct from initial query.
            performanceOutcome = .success
        } catch is CancellationError {
            if model.journalRecentEntriesAreCurrent,
               loadIdentifier == expectedIdentifier { isLoadingPage = false }
        } catch {
            if model.journalRecentEntriesAreCurrent,
               loadIdentifier == expectedIdentifier {
                isLoadingPage = false
                paginationErrorMessage = safeUserMessage(for: error, context: .read)
                performanceOutcome = .failure
            }
        }
    }

    @MainActor
    private func beginPaginationMeasurement(
        loadIdentifier: HistoryLoadIdentifier
    ) -> UUID {
        finishPaginationMeasurement(outcome: .cancelled)
        let id = UUID()
        paginationPerformanceMeasurement = HistoryPerformanceMeasurement(
            id: id,
            loadIdentifier: loadIdentifier,
            interval: MoneyUpPerformanceSignposts.begin(.historyPageToContent)
        )
        return id
    }

    @MainActor
    private func finishPaginationMeasurement(
        id: UUID? = nil,
        loadIdentifier: HistoryLoadIdentifier? = nil,
        outcome: MoneyUpPerformanceOutcome
    ) {
        guard let measurement = paginationPerformanceMeasurement,
              id == nil || measurement.id == id,
              loadIdentifier == nil
                || measurement.loadIdentifier == loadIdentifier else { return }
        paginationPerformanceMeasurement = nil
        MoneyUpPerformanceSignposts.end(
            measurement.interval,
            outcome: outcome
        )
    }

    @MainActor
    private func requestNextPageWhenReady() {
        guard nextCursor != nil else { return }
        guard !isInitialHistoryLoadInProgress else {
            pendingPaginationAfterInitialLoad = true
            return
        }
        Task { await loadNextPage() }
    }
}
