import MoneyUpCore
import SwiftUI

struct BudgetPlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appReportingSnapshot) private var sharedSnapshot
    @State private var selectedDate: Date?
    @State private var currencyCode: String?
    @State private var presentation: DerivedValue<MonthlyBudgetPresentation>?
    @State private var editingNode: BudgetNode?
    @State private var isAddingCategory = false
    @State private var isManagingCategories = false
    @State private var errorMessage: String?
    @State private var displayedPacingCadence: BudgetPacingCadence = .daily
    @AppStorage(MoneyUpDisclosureSection.planBudgetDetail.rawValue)
    private var showsRowDetail = false

    private var now: Date { sharedSnapshot?.instant ?? model.currentDateForUserAction() }
    private var date: Date {
        guard let selectedDate,
              !model.reportingCalendar.isDate(selectedDate, equalTo: now, toGranularity: .month)
        else { return now }
        return model.reportingCalendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
    }
    private var currency: CurrencyCode? {
        currencyCode.flatMap { try? CurrencyCode($0) } ?? model.profile?.baseCurrency
    }
    private var isCurrentMonth: Bool {
        model.reportingCalendar.isDate(date, equalTo: now, toGranularity: .month)
    }
    private var isClosed: Bool {
        (model.reportingCalendar.dateInterval(of: .month, for: date)?.end ?? date) <= now
    }
    private var loadIdentity: String {
        let parts = model.reportingCalendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(currency?.value ?? "")-"
            + "\(model.budgetNodesRevision)-\(model.journalProjectionRevision)-"
            + "\(model.logicalBookRevision)-\(model.isJournalMutationInProgress)"
    }

    var body: some View {
        List {
            scopeSection
            if isClosed {
                Section { Label("budget.closed_period", systemImage: "clock.badge.checkmark") }
            }
            if let presentation {
                switch presentation {
                case let .available(snapshot):
                    budgetContent(snapshot)
                case let .unavailable(issue):
                    Section {
                        DerivedValueUnavailableView(issue: issue, prominent: true)
                        Button("action.retry") { Task { await load() } }
                    }
                }
            } else {
                Section { ProgressView("budget.loading") }
            }
            if isCurrentMonth { exploreSection }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("plan.budget")
        .task(id: loadIdentity) { await load() }
        .toolbar { toolbar }
        .sheet(item: $editingNode) { node in
            BudgetEditorSheet(
                node: node, asOf: date, currency: currency,
                childAllocation: presentation?.value?.progress.first { $0.node.id == node.id }?.childAllocation
            )
        }
        .sheet(isPresented: $isAddingCategory) { AddCategorySheet(kind: .expense) }
        .sheet(isPresented: $isManagingCategories) { CategoryManagementList() }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private var scopeSection: some View {
        Section {
            DatePicker("budget.month", selection: Binding(
                get: { selectedDate ?? now }, set: { selectedDate = $0 }
            ), displayedComponents: .date)
            .environment(\.calendar, model.reportingCalendar)
            .environment(\.timeZone, model.reportingCalendar.timeZone)
            SearchableCurrencyPicker(
                title: "transaction.currency",
                selection: Binding(
                    get: { currency?.value ?? "" }, set: { currencyCode = $0 }
                ), existing: model.budgetCurrencies
            )
        } footer: {
            Text("budget.scope_detail")
        }
    }

    @ViewBuilder
    private func budgetContent(_ snapshot: MonthlyBudgetPresentation) -> some View {
        let outline = BudgetOutline.items(snapshot.progress.map(\.node))
        let progress = Dictionary(uniqueKeysWithValues: snapshot.progress.map { ($0.node.id, $0) })
        if let summary = snapshot.summary {
            Section {
                BudgetSummaryCard(
                    limit: summary.limit, spent: summary.spent, remaining: summary.remaining,
                    elapsed: isCurrentMonth ? sharedSnapshot?.monthElapsed ?? 0 : isClosed ? 1 : 0
                )
                if !summary.unbudgetedSpent.isZero {
                    LabeledContent("budget.unbudgeted_spending", value: formattedMoney(summary.unbudgetedSpent))
                }
            }
        }
        if isCurrentMonth, model.displayPreferences.showsDailyGuidance {
            Section {
                Picker("plan.pacing_view", selection: $displayedPacingCadence) {
                    Text("plan.pacing.today").tag(BudgetPacingCadence.daily)
                    Text("plan.pacing.this_week").tag(BudgetPacingCadence.weekly)
                    Text("plan.pacing.rest_of_month").tag(BudgetPacingCadence.monthly)
                }.pickerStyle(.segmented)
            }
        }
        ForEach(outline.filter { $0.depth == 0 }) { root in
            Section {
                ForEach(outline.filter { $0.rootID == root.id }) { item in
                    categoryRow(item, progress: progress[item.id], snapshot: snapshot)
                }
            } header: {
                Text(root.node.name).font(.title3.weight(.semibold)).foregroundStyle(.primary)
            }
        }
        if outline.isEmpty {
            Section {
                ContentUnavailableView("plan.empty", systemImage: "square.grid.2x2")
                Button("category.add") { isAddingCategory = true }
            }
        }
    }

    private func categoryRow(
        _ item: BudgetOutlineItem,
        progress: BudgetProgress?,
        snapshot: MonthlyBudgetPresentation
    ) -> some View {
        Button { editingNode = item.node } label: {
            VStack(alignment: .leading, spacing: 6) {
                BudgetRow(
                    node: item.node, depth: item.depth, progress: progress,
                    elapsed: isCurrentMonth ? sharedSnapshot?.monthElapsed ?? 0 : isClosed ? 1 : 0,
                    purpose: snapshot.purposes[item.id] ?? .unclassified,
                    displayedPacingCadence: displayedPacingCadence,
                    showsDetail: showsRowDetail, reportingDate: date,
                    showsName: item.depth != 0, showsPacing: isCurrentMonth
                )
                if item.node.allocationMode == .fixedTotal, item.node.limit != nil,
                   let child = progress?.childAllocation {
                    Text(child.amount > (item.node.limit?.amount ?? .zero)
                        ? "budget.children_overallocated" : "budget.fixed_total_detail")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let directRemaining = progress?.directRemaining, directRemaining.amount < .zero {
                    Label("budget.direct_overspent", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isClosed)
        .contextMenu {
            Button("lifecycle.manage_categories") { isManagingCategories = true }
            Button(model.isBudgetNodePinned(item.id) ? "plan.unpin_from_today" : "plan.pin_to_today") {
                Task {
                    do { try await model.setBudgetNodePinned(item.id, isPinned: !model.isBudgetNodePinned(item.id)) }
                    catch { errorMessage = safeUserMessage(for: error, context: .save) }
                }
            }
        }
    }

    private var exploreSection: some View {
        Section("simulator.explore") {
            NavigationLink { BudgetSimulatorView() } label: {
                Label("simulator.title", systemImage: "slider.horizontal.3")
            }
            if model.profile?.intelligenceEnabled == true {
                NavigationLink { BudgetSuggestionReviewView() } label: {
                    Label("intelligence.budget.review_title", systemImage: "wand.and.stars")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("budget.show_details", isOn: $showsRowDetail)
                NavigationLink { DisplaySettingsView() } label: { Text("display.title") }
            } label: { Label("display.short_title", systemImage: "slider.horizontal.3") }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { isManagingCategories = true } label: {
                Label("lifecycle.manage_categories", systemImage: "square.grid.2x2")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { isAddingCategory = true } label: { Label("category.add", systemImage: "plus") }
        }
    }

    private func load() async {
        presentation = nil
        guard let currency, !model.isJournalMutationInProgress else { return }
        let result = await model.monthlyBudgetPresentation(asOf: date, currency: currency)
        guard !Task.isCancelled else { return }
        presentation = result
    }
}
