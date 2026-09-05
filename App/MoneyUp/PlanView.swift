import MoneyUpCore
import SwiftUI

enum PlanSection: String, CaseIterable, Hashable {
    case budget
    case calendar
    case goals
    case allowances

    static let ordered: [PlanSection] = [
        .budget, .calendar, .goals, .allowances
    ]

    var titleKeyString: String {
        switch self {
        case .budget: "plan.budget"
        case .goals: "plan.goals"
        case .allowances: "allowance.short_title"
        case .calendar: "tab.calendar"
        }
    }

    var title: LocalizedStringKey { LocalizedStringKey(titleKeyString) }

    var systemImage: String {
        switch self {
        case .budget: "chart.pie.fill"
        case .goals: "target"
        case .allowances: "giftcard.fill"
        case .calendar: "calendar"
        }
    }
}

enum PlanSectionSelectorPolicy {
    static func usesMenu(at dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    static func showsTitle(
        for section: PlanSection,
        selection: PlanSection
    ) -> Bool {
        true
    }
}

struct PlanView: View {
    @State private var selection: PlanSection = .budget
    @Environment(AppModel.self) private var model
    @Environment(\.appReportingSnapshot) private var sharedReportingSnapshot
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(MoneyAmountPrivacy.storageKey)
    private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts

    var body: some View {
        let _ = hidesAmounts
        let snapshot = reportingSnapshot
        return NavigationStack {
            sectionRoot
                // This modifier belongs to the stack's root screen. Pushed
                // destinations replace it and therefore receive the native
                // Back control without carrying the peer-section selector.
                .safeAreaInset(edge: .top, spacing: 0) {
                    sectionSwitcher
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        MoneyUpAmountPrivacyButton()
                    }
                }
        }
        .environment(\.calendar, snapshot.calendar)
        .environment(\.timeZone, snapshot.calendar.timeZone)
    }

    private var reportingSnapshot: AppReportingSnapshot {
        sharedReportingSnapshot
            ?? AppReportingSnapshot(
                instant: model.currentDateForUserAction(),
                calendar: model.reportingCalendar
            )
    }

    @ViewBuilder
    private var sectionRoot: some View {
        switch selection {
        case .budget:
            BudgetPlanView()
        case .goals:
            SavingsGoalsView()
        case .allowances:
            AllowanceCenterView()
        case .calendar:
            CalendarView(providesNavigationStack: false)
        }
    }

    @ViewBuilder
    private var sectionSwitcher: some View {
        Group {
            if PlanSectionSelectorPolicy.usesMenu(at: dynamicTypeSize) {
                sectionMenu
            } else {
                ViewThatFits(in: .horizontal) {
                    compactSectionStrip
                    sectionMenu
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.bar)
    }

    private var compactSectionStrip: some View {
        HStack(spacing: 4) {
            ForEach(PlanSection.ordered, id: \.self) { section in
                sectionButton(section)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sectionMenu: some View {
        Menu {
            ForEach(PlanSection.ordered, id: \.self) { section in
                Button {
                    select(section)
                } label: {
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(
                            systemName: selection == section
                                ? "checkmark.circle.fill"
                                : section.systemImage
                        )
                    }
                }
                .accessibilityAddTraits(
                    selection == section ? .isSelected : []
                )
            }
        } label: {
            HStack {
                Label(selection.title, systemImage: selection.systemImage)
                Spacer()
                Image(systemName: "chevron.down").font(.caption).accessibilityHidden(true)
            }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .accessibilityLabel("plan.section_picker")
        .accessibilityValue(Text(selection.title))
    }

    private func sectionButton(_ section: PlanSection) -> some View {
        let isSelected = selection == section
        return Button {
            select(section)
        } label: {
            Group {
                if PlanSectionSelectorPolicy.showsTitle(
                    for: section,
                    selection: selection
                ) {
                    Text(section.title)
                        .padding(.horizontal, 12)
                } else {
                    Image(systemName: section.systemImage)
                        .frame(width: 44)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color.secondary.opacity(0.10),
                in: Capsule()
            )
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ section: PlanSection) {
        guard selection != section else { return }
        withAnimation(
            MoneyUpMotion.animation(
                for: .selection,
                reduceMotion: reduceMotion
            )
        ) {
            selection = section
        }
    }
}

struct BudgetRow: View {
    @Environment(AppModel.self) private var model
    let node: BudgetNode
    let depth: Int
    let progress: BudgetProgress?
    let elapsed: Double
    let purpose: BudgetPurpose
    let displayedPacingCadence: BudgetPacingCadence
    let showsDetail: Bool
    let reportingDate: Date
    var showsName = true
    var showsPacing = true

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
                Text(showsName ? node.name : AppLocalization.string("budget.group_total"))
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


            if node.limit != nil, showsDetail || purpose == .unclassified {
                // An unclassified limit is a setup gap the user has to see,
                // so it stays visible whatever the detail switch says.
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
                if showsDetail {
                    Text(
                        String(
                            format: AppLocalization.string("plan.spent_of_limit"),
                            formattedMoney(spent),
                            formattedMoney(limit)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if showsPacing, model.displayPreferences.showsGuidance(for: node.id), let progress {
                    switch model.budgetPace(
                        for: progress,
                        cadence: displayedPacingCadence,
                        purpose: purpose,
                        asOf: reportingDate
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

struct BudgetSummaryCard: View {
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

            MoneyUpExplainer("plan.pace_hint")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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
    @State private var isDiscarding = false
    private let originalParentID: UUID?
    let kind: LedgerAccountKind
    let onAdded: @MainActor (UUID) -> Void

    init(
        kind: LedgerAccountKind,
        initialParentID: UUID? = nil,
        onAdded: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.kind = kind
        self.originalParentID = initialParentID
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
            .disabled(isSaving)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") {
                        if !name.isEmpty || parentID != originalParentID { isDiscarding = true }
                        else { dismiss() }
                    }.disabled(isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .confirmationDialog("draft.discard_title", isPresented: $isDiscarding, titleVisibility: .visible) {
                Button("draft.discard_changes", role: .destructive) { dismiss() }
                Button("draft.keep_editing", role: .cancel) {}
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .interactiveDismissDisabled(isSaving || !name.isEmpty || parentID != originalParentID)
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
