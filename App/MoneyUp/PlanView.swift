import MoneyUpCore
import SwiftUI

struct PlanView: View {
    fileprivate enum Section: Hashable {
        case overview
        case budget
        case goals
        case allowances
        case calendar
    }

    /// The overview is the tab's root rather than a chip, so the chip bar and
    /// the overview list stop offering the same four destinations twice.
    fileprivate static let switchableSections: [Section] = [
        .budget, .calendar, .goals, .allowances
    ]

    @State private var selection: Section = .overview
    @Environment(AppModel.self) private var model

    /// Sections are swapped, not pushed, so the way back to the overview has
    /// to be published explicitly for each section to place.
    private var sectionBack: MoneyUpSectionBackAction? {
        guard selection != .overview else { return nil }
        return MoneyUpSectionBackAction(titleKey: "plan.overview") {
            withAnimation(.snappy) { selection = .overview }
        }
    }

    var body: some View {
        Group {
            switch selection {
            case .overview:
                PlanOverviewView { selection = $0 }
            case .budget:
                BudgetPlanView(sectionBack: sectionBack)
            case .goals:
                SavingsGoalsView(sectionBack: sectionBack)
            case .allowances:
                AllowanceCenterView(sectionBack: sectionBack)
            case .calendar:
                CalendarView(
                    providesNavigationStack: true,
                    sectionBack: sectionBack
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            sectionSwitcher
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private var sectionSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.switchableSections, id: \.self) { section in
                    Button {
                        withAnimation(.snappy) { selection = section }
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selection == section
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.secondary.opacity(0.10),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private extension PlanView.Section {
    var title: LocalizedStringKey {
        switch self {
        case .overview: "plan.overview"
        case .budget: "plan.budget"
        case .goals: "plan.goals"
        case .allowances: "allowance.short_title"
        case .calendar: "tab.calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .budget: "chart.pie.fill"
        case .goals: "target"
        case .allowances: "giftcard.fill"
        case .calendar: "calendar"
        }
    }
}

private struct PlanOverviewView: View {
    @Environment(AppModel.self) private var model
    let open: (PlanView.Section) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    overviewRow(
                        title: "plan.budget",
                        detail: String(
                            format: AppLocalization.string("plan.overview.budget_count"),
                            model.budgetNodes.count
                        ),
                        symbol: "chart.pie.fill",
                        section: .budget
                    )
                    overviewRow(
                        title: "tab.calendar",
                        detail: String(
                            format: AppLocalization.string("plan.overview.schedule_count"),
                            model.scheduledTransactions.filter(\.isActive).count
                        ),
                        symbol: "calendar.badge.clock",
                        section: .calendar
                    )
                    overviewRow(
                        title: "plan.goals",
                        detail: String(
                            format: AppLocalization.string("plan.overview.goal_count"),
                            model.savingsGoals.filter { !$0.isArchived }.count
                        ),
                        symbol: "target",
                        section: .goals
                    )
                    overviewRow(
                        title: "allowance.short_title",
                        detail: String(
                            format: AppLocalization.string("plan.overview.allowance_count"),
                            model.allowancePlans.filter { !$0.isArchived }.count
                        ),
                        symbol: "giftcard.fill",
                        section: .allowances
                    )
                } header: {
                    Text("plan.overview.next")
                } footer: {
                    Text("plan.overview.detail")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("tab.plan")
        }
    }

    private func overviewRow(
        title: LocalizedStringKey,
        detail: String,
        symbol: String,
        section: PlanView.Section
    ) -> some View {
        Button { open(section) } label: {
            HStack(spacing: 12) {
                MoneyUpSymbolBadge(systemImage: symbol, color: .accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private struct BudgetPlanView: View {
    let sectionBack: MoneyUpSectionBackAction?

    init(sectionBack: MoneyUpSectionBackAction? = nil) {
        self.sectionBack = sectionBack
    }

    @Environment(AppModel.self) private var model
    @State private var editingNode: BudgetNode?
    @State private var isAddingCategory = false
    @State private var categoryKindToAdd: LedgerAccountKind = .expense
    @State private var isManagingCategories = false
    @State private var displayedPacingCadence: BudgetPacingCadence = .daily
    @State private var errorMessage: String?

    /// How far through the month we are, drawn on every bar so a number can be
    /// read as ahead or behind rather than just large.
    private var monthElapsed: Double {
        let calendar = model.reportingCalendar
        let now = Date()
        guard let month = calendar.dateInterval(of: .month, for: now) else { return 0 }
        let span = month.end.timeIntervalSince(month.start)
        guard span > 0 else { return 0 }
        return min(max(now.timeIntervalSince(month.start) / span, 0), 1)
    }

    /// Pinning from the budget list keeps the choice next to the category it
    /// concerns, rather than only inside the Today board's editor.
    @ViewBuilder
    private func pinAction(for node: BudgetNode) -> some View {
        let isPinned = model.isBudgetNodePinned(node.id)
        if isPinned || model.canPinAnotherBudgetNode {
            Button {
                Task { await togglePin(node, isPinned: isPinned) }
            } label: {
                Label(
                    isPinned ? "plan.unpin_from_today" : "plan.pin_to_today",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            .tint(.accentColor)
        }
    }

    private func togglePin(_ node: BudgetNode, isPinned: Bool) async {
        do {
            try await model.setBudgetNodePinned(node.id, isPinned: !isPinned)
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func progressByIDResult() -> DerivedValue<[UUID: BudgetProgress]> {
        switch model.budgetProgressThisMonthResult() {
        case let .available(progress):
            return .available(
                Dictionary(
                    uniqueKeysWithValues: progress.map { ($0.node.id, $0) }
                )
            )
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    var body: some View {
        // Resolved once per update. Reading it inside the row loop recomputed
        // the whole budget tree for every category on screen.
        let progressResult = progressByIDResult()
        let elapsed = monthElapsed
        let foreignSpendingResult = model.excludedForeignSpendingThisMonthResult()
        let summaryResult = model.budgetPlanSummaryThisMonthResult()
        let purposeOverview = model.budgetPurposeOverview()
        let purposes = purposeOverview.effectivePurposeByID
        let needsPurposeCount = purposeOverview.reviewCount

        return NavigationStack {
            List {
                Section {
                    Picker("plan.pacing_view", selection: $displayedPacingCadence) {
                        Text("plan.pacing.today").tag(BudgetPacingCadence.daily)
                        Text("plan.pacing.this_week").tag(BudgetPacingCadence.weekly)
                        Text("plan.pacing.rest_of_month").tag(BudgetPacingCadence.monthly)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("plan.pacing_view_detail")
                }

                if case let .available(.some(summary)) = summaryResult {
                    Section {
                        BudgetSummaryCard(
                            limit: summary.limit,
                            spent: summary.spent,
                            remaining: summary.remaining,
                            elapsed: elapsed
                        )
                    }
                } else if case let .unavailable(issue) = summaryResult {
                    Section {
                        DerivedValueUnavailableView(
                            issue: issue,
                            prominent: true
                        )
                    }
                }

                if needsPurposeCount > 0 {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    String(
                                        format: AppLocalization.string("plan.purpose_review_title"),
                                        needsPurposeCount
                                    )
                                )
                                .font(.headline)
                                Text("plan.purpose_review_detail")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    if model.profile?.intelligenceEnabled == true {
                        NavigationLink {
                            BudgetSuggestionReviewView()
                        } label: {
                            HStack(spacing: 12) {
                                MoneyUpSymbolBadge(
                                    systemImage: "wand.and.stars",
                                    color: .accentColor
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("intelligence.budget.review_title")
                                        .font(.headline)
                                    Text("intelligence.budget.row_detail")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    NavigationLink {
                        BudgetSimulatorView()
                    } label: {
                        HStack(spacing: 12) {
                            MoneyUpSymbolBadge(
                                systemImage: "slider.horizontal.3",
                                color: .accentColor
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text("simulator.title")
                                    .font(.headline)
                                Text("simulator.row_detail")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("simulator.explore")
                }

                if case let .available(foreignSpending) = foreignSpendingResult,
                   !foreignSpending.isEmpty {
                    Section {
                        ForEach(foreignSpending, id: \.currency) { money in
                            LabeledContent(
                                "plan.foreign_not_counted",
                                value: formattedMoney(money)
                            )
                        }
                    } footer: {
                        Text("plan.foreign_not_counted_detail")
                    }
                } else if case let .unavailable(issue) = foreignSpendingResult {
                    Section {
                        DerivedValueUnavailableView(issue: issue)
                    }
                }

                Section {
                    switch progressResult {
                    case let .available(progress):
                        ForEach(model.budgetNodeOutline) { item in
                            Button {
                                editingNode = item.node
                            } label: {
                                BudgetRow(
                                    node: item.node,
                                    depth: item.depth,
                                    progress: progress[item.node.id],
                                    elapsed: elapsed,
                                    purpose: purposes[item.node.id] ?? .unclassified,
                                    displayedPacingCadence: displayedPacingCadence
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading) {
                                pinAction(for: item.node)
                            }
                        }
                    case let .unavailable(issue):
                        ForEach(model.budgetNodeOutline) { item in
                            Button {
                                editingNode = item.node
                            } label: {
                                HStack {
                                    Text(item.node.name)
                                    Spacer()
                                    Text("—")
                                        .monospacedDigit()
                                }
                                .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
                                .accessibilityLabel(
                                    "\(item.node.name), \(issue.localizedDescription)"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("plan.this_month")
                } footer: {
                    Text("plan.rollup_detail")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .overlay {
                if model.budgetNodes.isEmpty {
                    VStack(spacing: 12) {
                        MoneyUpIllustration("MoneyUpScenarioStudio", role: .empty)
                        Text("plan.empty")
                            .font(.title2.bold())
                        Text("plan.empty_detail")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            categoryKindToAdd = .expense
                            isAddingCategory = true
                        } label: {
                            Label("category.add", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.moneyUpAction)
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(
                        cornerRadius: 24,
                        style: .continuous
                    ))
                    .padding()
                }
            }
            .navigationTitle("plan.budget")
            .moneyUpSectionBackToolbar(sectionBack)
            .moneyUpOperationErrorAlert(message: $errorMessage)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            categoryKindToAdd = .expense
                            isAddingCategory = true
                        } label: {
                            Label("lifecycle.add_expense_category", systemImage: "minus.circle")
                        }
                        Button {
                            categoryKindToAdd = .income
                            isAddingCategory = true
                        } label: {
                            Label("lifecycle.add_income_category", systemImage: "plus.circle")
                        }
                        Button {
                            isManagingCategories = true
                        } label: {
                            Label("lifecycle.manage_categories", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Label("category.add", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $editingNode) { node in
                BudgetEditorSheet(node: node)
            }
            .sheet(isPresented: $isAddingCategory) {
                AddCategorySheet(kind: categoryKindToAdd)
            }
            .sheet(isPresented: $isManagingCategories) {
                CategoryManagementList()
            }
        }
    }
}

private struct BudgetRow: View {
    @Environment(AppModel.self) private var model
    let node: BudgetNode
    let depth: Int
    let progress: BudgetProgress?
    let elapsed: Double
    let purpose: BudgetPurpose
    let displayedPacingCadence: BudgetPacingCadence

    private var spent: Money? { progress?.spent }

    private var ratio: DerivedValue<Double?> {
        guard let limit = progress?.effectiveLimit?.amount,
              let spent = spent?.amount else { return .available(nil) }
        switch moneyUpPaceRatio(
            spent: spent,
            limit: limit,
            operation: "budget-row-ratio"
        ) {
        case let .available(ratio): return .available(ratio)
        case let .unavailable(issue): return .unavailable(issue)
        }
    }

    private var remaining: Money? { progress?.remaining }

    private var isOverspent: Bool {
        guard let remaining else { return false }
        return remaining.amount < .zero
    }

    var body: some View {
        let ratioResult = ratio
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(node.name)
                    .fontWeight(depth == 0 ? .semibold : .regular)
                    .foregroundStyle(depth == 0 ? .primary : .secondary)
                Spacer(minLength: 8)

                if let remaining {
                    Text(formattedMoney(isOverspent ? remaining.negated : remaining))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isOverspent ? Color.red : Color.primary)
                    Text(isOverspent ? "plan.over" : "plan.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let spent, !spent.isZero {
                    Text(formattedMoney(spent))
                        .font(.subheadline.monospacedDigit())
                }
            }


            if node.limit != nil {
                HStack(spacing: 10) {
                    Label(purpose.titleKey, systemImage: purpose.systemImage)
                    if node.rolloverRule != .none {
                        Label(
                            node.rolloverRule.titleKey,
                            systemImage: "arrow.turn.down.right"
                        )
                    }
                    if node.pacingCadence != .monthly {
                        Label(
                            node.pacingCadence.titleKey,
                            systemImage: "gauge.with.dots.needle.50percent"
                        )
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(purpose == .unclassified ? Color.orange : Color.accentColor)
            }

            if case let .available(.some(ratio)) = ratioResult,
               let limit = progress?.effectiveLimit, let spent {
                MoneyUpPaceBar(ratio: ratio, elapsed: elapsed)
                Text(
                    String(
                        format: AppLocalization.string("plan.spent_of_limit"),
                        formattedMoney(spent),
                        formattedMoney(limit)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let progress {
                    switch model.budgetPace(
                        for: progress,
                        cadence: displayedPacingCadence
                    ) {
                    case let .available(.some(pace)):
                        Text(
                            String(
                                format: AppLocalization.string("plan.pace_available"),
                                formattedMoney(pace.available),
                                AppLocalization.string(pace.cadence.titleKeyString)
                            )
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    case let .unavailable(issue):
                        DerivedValueUnavailableView(issue: issue)
                    case .available(nil):
                        EmptyView()
                    }
                }
            } else if case let .unavailable(issue) = ratioResult {
                DerivedValueUnavailableView(issue: issue)
            } else {
                Text("plan.tap_to_set_limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, CGFloat(min(depth, 4)) * 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct BudgetSummaryCard: View {
    let limit: Money
    let spent: Money
    let remaining: Money
    let elapsed: Double

    private var ratio: DerivedValue<Double> {
        moneyUpPaceRatio(
            spent: spent.amount,
            limit: limit.amount,
            operation: "budget-summary-ratio"
        )
    }

    private var isOverspent: Bool { remaining.amount < .zero }

    var body: some View {
        let ratioResult = ratio
        VStack(alignment: .leading, spacing: 12) {
            Text(isOverspent ? "plan.total_over" : "plan.total_left")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(formattedMoney(isOverspent ? remaining.negated : remaining))
                .moneyUpFinancialValue(.hero)
                .foregroundStyle(isOverspent ? Color.red : Color.primary)

            switch ratioResult {
            case let .available(ratio):
                MoneyUpPaceBar(ratio: ratio, elapsed: elapsed)
            case let .unavailable(issue):
                DerivedValueUnavailableView(issue: issue)
            }

            Text(
                String(
                    format: AppLocalization.string("plan.spent_of_limit"),
                    formattedMoney(spent),
                    formattedMoney(limit)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Label("plan.pace_hint", systemImage: "line.diagonal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct BudgetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let node: BudgetNode

    @State private var amountText: String
    @State private var purpose: BudgetPurpose
    @State private var pacingCadence: BudgetPacingCadence
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(node: BudgetNode) {
        self.node = node
        _amountText = State(
            initialValue: node.limit.map {
                editableAmount($0.amount)
            } ?? ""
        )
        _purpose = State(initialValue: node.purpose)
        _pacingCadence = State(initialValue: node.pacingCadence)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("quick_log.amount", text: $amountText)
                        .moneyAmountKeyboard(currency: model.profile?.baseCurrency)
                } header: {
                    Text("plan.monthly_limit")
                } footer: {
                    Text("plan.blank_removes_limit")
                }
                Section {
                    Picker("plan.purpose", selection: $purpose) {
                        ForEach(BudgetPurpose.allCases, id: \.self) { option in
                            Label(option.titleKey, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                } header: {
                    Text("plan.purpose")
                } footer: {
                    Text("plan.purpose_detail")
                }
                if purpose == .flexible {
                    Section {
                        Picker("plan.pacing", selection: $pacingCadence) {
                            ForEach(BudgetPacingCadence.allCases, id: \.self) { cadence in
                                Text(cadence.titleKey).tag(cadence)
                            }
                        }
                    } footer: {
                        Text("plan.pacing_detail")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(node.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(
                            isSaving
                                || (!amountText.isEmpty && decimalAmount(from: amountText) == nil)
                                || (!amountText.isEmpty && purpose == .unclassified)
                        )
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.setBudgetLimit(
                categoryID: node.id,
                amount: trimmed.isEmpty ? nil : decimalAmount(from: trimmed),
                purpose: purpose,
                pacingCadence: purpose == .flexible ? pacingCadence : .monthly
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

extension BudgetPurpose {
    var titleKey: LocalizedStringKey {
        switch self {
        case .unclassified: "plan.purpose.unclassified"
        case .flexible: "plan.purpose.flexible"
        case .commitment: "plan.purpose.commitment"
        case .debt: "plan.purpose.debt"
        case .goal: "plan.purpose.goal"
        }
    }

    var systemImage: String {
        switch self {
        case .unclassified: "questionmark.circle"
        case .flexible: "basket.fill"
        case .commitment: "calendar.badge.clock"
        case .debt: "creditcard.fill"
        case .goal: "target"
        }
    }
}

extension BudgetRolloverRule {
    var titleKey: LocalizedStringKey {
        switch self {
        case .none: "plan.rollover.none"
        case .positiveOnly: "plan.rollover.positive_only"
        case .fullBalance: "plan.rollover.full_balance"
        }
    }
}

extension BudgetPacingCadence {
    var titleKeyString: String {
        switch self {
        case .monthly: "plan.pacing.monthly"
        case .daily: "plan.pacing.daily"
        case .weekly: "plan.pacing.weekly"
        }
    }

    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }
}

struct AddCategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?
    let kind: LedgerAccountKind
    let onAdded: @MainActor (UUID) -> Void

    init(
        kind: LedgerAccountKind,
        initialParentID: UUID? = nil,
        onAdded: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.kind = kind
        self.onAdded = onAdded
        _parentID = State(initialValue: initialParentID)
    }

    private var titleKey: LocalizedStringKey {
        kind == .income
            ? "lifecycle.add_income_category"
            : "lifecycle.add_expense_category"
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("category.name", text: $name)
                Picker("category.parent", selection: $parentID) {
                    Text("category.no_parent").tag(UUID?.none)
                    ForEach(model.accounts.filter {
                        $0.kind == kind && !$0.isArchived && $0.systemRole == nil
                    }) { category in
                        Text(model.categoryPathName(for: category.id))
                            .tag(Optional(category.id))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let categoryID = try await model.addCategory(
                name: name,
                kind: kind,
                parentID: parentID
            )
            onAdded(categoryID)
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
