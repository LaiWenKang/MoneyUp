import Charts
import MoneyUpCore
import SwiftUI

struct PlanView: View {
    private enum Section: Hashable {
        case budget
        case goals
        case calendar
    }

    @State private var selection: Section = .budget
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch selection {
            case .budget:
                BudgetPlanView()
            case .goals:
                SavingsGoalsView()
            case .calendar:
                CalendarView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("tab.plan", selection: $selection) {
                Text("plan.budget").tag(Section.budget)
                Text("plan.goals").tag(Section.goals)
                Text("tab.calendar").tag(Section.calendar)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }
}

private struct BudgetPlanView: View {
    private struct IndentedNode: Identifiable {
        let node: BudgetNode
        let depth: Int
        var id: UUID { node.id }
    }

    @EnvironmentObject private var model: AppModel
    @State private var editingNode: BudgetNode?
    @State private var isAddingCategory = false
    @State private var categoryKindToAdd: LedgerAccountKind = .expense
    @State private var isManagingCategories = false

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

    private var orderedNodes: [IndentedNode] {
        var result: [IndentedNode] = []
        let children = Dictionary(grouping: model.budgetNodes, by: \.parentID)

        func appendChildren(of parentID: UUID?, depth: Int) {
            for node in (children[parentID] ?? []).sorted(by: { $0.name < $1.name }) {
                result.append(IndentedNode(node: node, depth: depth))
                appendChildren(of: node.id, depth: depth + 1)
            }
        }
        appendChildren(of: nil, depth: 0)
        return result
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
                                        format: String(localized: "plan.purpose_review_title"),
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
                        ForEach(orderedNodes) { item in
                            Button {
                                editingNode = item.node
                            } label: {
                                BudgetRow(
                                    node: item.node,
                                    depth: item.depth,
                                    progress: progress[item.node.id],
                                    elapsed: elapsed,
                                    purpose: purposes[item.node.id] ?? .unclassified
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    case let .unavailable(issue):
                        ForEach(orderedNodes) { item in
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
            .navigationTitle("tab.plan")
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
                CategoryManagementSheet(categoryID: node.id)
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
    let node: BudgetNode
    let depth: Int
    let progress: BudgetProgress?
    let elapsed: Double
    let purpose: BudgetPurpose

    private var spent: Money? { progress?.spent }

    private var ratio: DerivedValue<Double?> {
        guard let limit = progress?.effectiveLimit?.amount,
              let spent = spent?.amount else { return .available(nil) }
        if limit == .zero { return .available(spent > .zero ? 2 : 0) }
        guard limit > .zero else { return .available(nil) }
        do {
            return .available(
                NSDecimalNumber(
                    decimal: try CheckedDecimal.ratio(spent, limit)
                ).doubleValue
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "budget-row-ratio",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
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
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(purpose == .unclassified ? Color.orange : Color.accentColor)
            }

            if case let .available(.some(ratio)) = ratioResult,
               let limit = progress?.effectiveLimit, let spent {
                MoneyUpPaceBar(ratio: ratio, elapsed: elapsed)
                Text(
                    String(
                        format: String(localized: "plan.spent_of_limit"),
                        formattedMoney(spent),
                        formattedMoney(limit)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
        guard limit.amount > .zero else {
            return .available(spent.amount > .zero ? 2 : 0)
        }
        do {
            return .available(
                NSDecimalNumber(
                    decimal: try CheckedDecimal.ratio(
                        spent.amount,
                        limit.amount
                    )
                ).doubleValue
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "budget-summary-ratio",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    private var isOverspent: Bool { remaining.amount < .zero }

    var body: some View {
        let ratioResult = ratio
        VStack(alignment: .leading, spacing: 12) {
            Text(isOverspent ? "plan.total_over" : "plan.total_left")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(formattedMoney(isOverspent ? remaining.negated : remaining))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(isOverspent ? Color.red : Color.primary)
                .contentTransition(.numericText())

            switch ratioResult {
            case let .available(ratio):
                MoneyUpPaceBar(ratio: ratio, elapsed: elapsed)
            case let .unavailable(issue):
                DerivedValueUnavailableView(issue: issue)
            }

            Text(
                String(
                    format: String(localized: "plan.spent_of_limit"),
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

private struct BudgetSimulatorView: View {
    private struct ChartPoint: Identifiable {
        let id: String
        let label: String
        let money: Money

        var amount: Double {
            NSDecimalNumber(decimal: money.amount).doubleValue
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var additionalSpendingText = ""
    @State private var additionalIncomeText = ""

    private var monthElapsed: Double {
        let calendar = model.reportingCalendar
        let now = Date()
        guard let month = calendar.dateInterval(of: .month, for: now) else { return 0 }
        let span = month.end.timeIntervalSince(month.start)
        guard span > 0 else { return 0 }
        return min(max(now.timeIntervalSince(month.start) / span, 0), 1)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                DashboardCard {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            simulatorIntroduction
                            MoneyUpIllustration("MoneyUpScenarioStudio", role: .inline)
                        }
                        VStack(spacing: 12) {
                            MoneyUpIllustration("MoneyUpScenarioStudio", role: .empty)
                            simulatorIntroduction
                        }
                    }
                }

                switch (
                    model.budgetPlanSummaryThisMonthResult(),
                    model.reportResult(for: .thisMonth)
                ) {
                case let (.available(.some(summary)), .available(report)):
                    simulator(summary: summary, report: report)
                case (.available(.none), _):
                    DashboardCard {
                        ContentUnavailableView(
                            "simulator.needs_budget",
                            systemImage: "chart.pie",
                            description: Text("simulator.needs_budget_detail")
                        )
                    }
                case let (.unavailable(issue), _), let (_, .unavailable(issue)):
                    DashboardCard {
                        DerivedValueUnavailableView(issue: issue, prominent: true)
                    }
                }
            }
            .padding()
        }
        .background { MoneyUpBackdrop() }
        .navigationTitle("simulator.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { MoneyUpKeyboardDoneToolbar() }
    }

    private var simulatorIntroduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("simulator.preview_only", systemImage: "eye.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text("simulator.title")
                .font(.title2.bold())
            Text("simulator.detail")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func simulator(
        summary: BudgetPlanSummary,
        report: PeriodReport
    ) -> some View {
        let currency = summary.limit.currency
        let additionalSpending = parsedAmount(
            additionalSpendingText,
            currency: currency
        )
        let additionalIncome = parsedAmount(
            additionalIncomeText,
            currency: currency
        )

        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("simulator.adjust", systemImage: "slider.horizontal.3")
                    .font(.headline)

                scenarioField(
                    "simulator.additional_spending",
                    text: $additionalSpendingText,
                    currency: currency,
                    isValid: additionalSpending != nil
                )

                Divider()

                scenarioField(
                    "simulator.additional_income",
                    text: $additionalIncomeText,
                    currency: currency,
                    isValid: additionalIncome != nil
                )

                Button("simulator.reset") {
                    additionalSpendingText = ""
                    additionalIncomeText = ""
                }
                .font(.subheadline.weight(.semibold))
                .disabled(additionalSpendingText.isEmpty && additionalIncomeText.isEmpty)
            }
        }

        if let additionalSpending, let additionalIncome {
            if let forecast = try? FinanceCalculator.budgetScenario(
                currentSpent: summary.spent,
                budgetLimit: summary.limit,
                currentIncome: report.baseFlow.income,
                additionalSpending: additionalSpending,
                additionalIncome: additionalIncome
            ) {
                forecastCards(forecast)
            } else {
                DashboardCard {
                    Text("simulator.unavailable")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            DashboardCard {
                Label(
                    "simulator.invalid_amount",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }
        }
    }

    private func scenarioField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        currency: CurrencyCode,
        isValid: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(currency.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            TextField("simulator.amount_placeholder", text: text)
                .moneyAmountKeyboard(currency: currency)
                .textFieldStyle(.roundedBorder)
            if !isValid {
                Text("simulator.invalid_amount")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func forecastCards(_ forecast: BudgetScenarioForecast) -> some View {
        let points = [
            ChartPoint(
                id: "current",
                label: String(localized: "simulator.current"),
                money: forecast.currentSpent
            ),
            ChartPoint(
                id: "projected",
                label: String(localized: "simulator.projected"),
                money: forecast.projectedSpent
            )
        ]
        let limit = NSDecimalNumber(decimal: forecast.budgetLimit.amount).doubleValue
        let isOver = forecast.projectedRemaining.amount < .zero
        let budgetUsage = budgetUsageResult(forecast)

        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("simulator.spending_chart", systemImage: "chart.bar.xaxis")
                    .font(.headline)

                Chart {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Scenario", point.label),
                            y: .value("Amount", point.amount)
                        )
                        .foregroundStyle(
                            point.id == "current"
                                ? Color.secondary
                                : (isOver ? Color.red : Color.accentColor)
                        )
                        .annotation(position: .top) {
                            Text(formattedMoney(point.money))
                                .font(.caption2.monospacedDigit())
                        }
                        .accessibilityLabel(point.label)
                        .accessibilityValue(formattedMoney(point.money))
                    }

                    RuleMark(y: .value("Budget", limit))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("simulator.budget_line")
                                .font(.caption2.weight(.semibold))
                        }
                }
                .frame(height: 240)
                .chartLegend(.hidden)
                .accessibilityLabel(Text("simulator.chart_accessibility"))

                if case let .available(.some(ratio)) = budgetUsage {
                    MoneyUpPaceBar(
                        ratio: NSDecimalNumber(decimal: ratio).doubleValue,
                        elapsed: monthElapsed
                    )
                } else if case let .unavailable(issue) = budgetUsage {
                    DerivedValueUnavailableView(issue: issue)
                }
            }
        }

        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(
                        isOver
                            ? LocalizedStringKey("simulator.projected_over")
                            : LocalizedStringKey("simulator.projected_left")
                    )
                } icon: {
                    Image(
                        systemName: isOver
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                }
                .font(.headline)
                .foregroundStyle(isOver ? Color.red : Color.primary)

                Text(
                    formattedMoney(
                        isOver
                            ? forecast.projectedRemaining.negated
                            : forecast.projectedRemaining
                    )
                )
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()

                Divider()

                LabeledContent("simulator.projected_income") {
                    Text(formattedMoney(forecast.projectedIncome))
                        .monospacedDigit()
                }
                LabeledContent("simulator.projected_spending") {
                    Text(formattedMoney(forecast.projectedSpent))
                        .monospacedDigit()
                }
                LabeledContent("simulator.projected_net") {
                    Text(formattedMoney(forecast.projectedNet))
                        .monospacedDigit()
                }

                Text("simulator.no_changes_saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func budgetUsageResult(
        _ forecast: BudgetScenarioForecast
    ) -> DerivedValue<Decimal?> {
        do {
            return .available(try forecast.budgetUsage())
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "budget-scenario-usage",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    private func parsedAmount(
        _ text: String,
        currency: CurrencyCode
    ) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .zero }
        guard let amount = decimalAmount(from: trimmed),
              amount >= .zero,
              currency.supports(amount) else { return nil }
        return amount
    }
}

private struct BudgetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let node: BudgetNode

    @State private var amountText: String
    @State private var purpose: BudgetPurpose
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
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
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
                purpose: purpose
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

private struct AddCategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?
    let kind: LedgerAccountKind

    private var titleKey: LocalizedStringKey {
        kind == .income
            ? "lifecycle.add_income_category"
            : "lifecycle.add_expense_category"
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("category.name", text: $name)
                if kind == .expense {
                    Picker("category.parent", selection: $parentID) {
                        Text("category.no_parent").tag(UUID?.none)
                        ForEach(model.expenseCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
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
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.addCategory(
                name: name,
                kind: kind,
                parentID: kind == .expense ? parentID : nil
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
