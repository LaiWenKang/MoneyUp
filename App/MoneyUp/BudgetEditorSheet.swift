import MoneyUpCore
import SwiftUI

struct BudgetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let node: BudgetNode
    let asOf: Date
    let currency: CurrencyCode?
    let childAllocation: Money?
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @FocusState private var amountFocused: Bool
    @State private var amountText: String
    @State private var purpose: BudgetPurpose
    @State private var mode: BudgetAllocationMode
    @State private var isSaving = false
    @State private var isDiscarding = false
    @State private var errorMessage: String?

    init(node: BudgetNode, asOf: Date, currency: CurrencyCode?, childAllocation: Money? = nil) {
        self.node = node
        self.asOf = asOf
        self.currency = currency
        self.childAllocation = childAllocation
        _amountText = State(initialValue: node.limit.map { editableAmount($0.amount) } ?? "")
        _purpose = State(initialValue: node.purpose)
        _mode = State(initialValue: node.limit == nil ? .automatic : node.allocationMode)
    }

    private var hasChanges: Bool {
        amountText != (node.limit.map { editableAmount($0.amount) } ?? "")
            || purpose != node.purpose
            || mode != (node.limit == nil ? .automatic : node.allocationMode)
    }
    private var trimmed: String { amountText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool {
        trimmed.isEmpty || (decimalAmount(from: trimmed).map { $0 >= .zero } == true
            && purpose != .unclassified)
    }
    private var amountValidationMessage: String? {
        isValid ? nil : AppLocalization.string("budget.invalid_allocation")
    }
    private var hasChildren: Bool { model.budgetNodes.contains { $0.parentID == node.id } }
    private var hasMonthlyOverride: Bool {
        guard let month = try? BudgetMonth(containing: asOf, calendar: model.reportingCalendar) else { return false }
        return node.monthlyAllocations.contains { $0.month == month && $0.currency == currency }
    }

    var body: some View {
        NavigationStack {
            Form {
                allocationSection
                if hasChildren {
                    Section {
                        Picker("budget.allocation_mode", selection: Binding(get: { mode }, set: { value in changeMode(value) })) {
                            Text("budget.mode.automatic").tag(BudgetAllocationMode.automatic)
                            Text("budget.mode.fixed_total").tag(BudgetAllocationMode.fixedTotal)
                        }
                        if let childAllocation {
                            LabeledContent("budget.child_total", value: formattedMoney(childAllocation))
                        }
                        allocationPreview
                    } footer: {
                        Text(mode == .automatic ? "budget.automatic_detail" : "budget.fixed_total_detail")
                    }
                }
                Section {
                    Picker("plan.purpose", selection: $purpose) {
                        ForEach(BudgetPurpose.allCases, id: \.self) { option in
                            Label(option.titleKey, systemImage: option.systemImage).tag(option)
                        }
                    }
                } footer: { MoneyUpExplainer("plan.purpose_detail") }
                Section {
                    Toggle("display.category_daily_guidance", isOn: Binding(
                        get: { !model.displayPreferences.hiddenGuidanceCategoryIDs.contains(node.id) },
                        set: { visible in
                            model.changeDisplayPreferences { $0.setGuidanceVisible(visible, for: node.id) }
                        }
                    ))
                } footer: { Text("display.category_guidance_detail") }
                if hasMonthlyOverride {
                    Section {
                        Button("budget.use_recurring") { Task { await useRecurring() } }
                    } footer: { Text("budget.use_recurring_detail") }
                }
            }
            .disabled(isSaving)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(node.name)
            .moneyUpNavigationSurface()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { if hasChanges { isDiscarding = true } else { dismiss() } }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }.disabled(isSaving || !isValid)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .confirmationDialog("draft.discard_title", isPresented: $isDiscarding, titleVisibility: .visible) {
                Button("draft.discard_changes", role: .destructive) { dismiss() }
                Button("draft.keep_editing", role: .cancel) {}
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .interactiveDismissDisabled(hasChanges || isSaving)
        .presentationDetents([.large])
    }

    private var allocationSection: some View {
        Section {
            TextField("quick_log.amount", text: $amountText)
                .moneyAmountKeyboard(currency: currency)
                .focused($amountFocused)
                .moneyUpPrivateAmountInput(
                    masked: hidesAmounts && !amountFocused && !amountText.isEmpty,
                    accessibilityLabel: Text("budget.monthly_allocation")
                ) { amountFocused = true }
                .moneyUpFieldValidation(amountValidationMessage)
            if let amountValidationMessage { MoneyUpFieldError(message: amountValidationMessage) }
        } header: {
            Text(mode == .automatic && hasChildren ? "budget.direct_allocation" : "budget.monthly_allocation")
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(asOf, format: .dateTime.month(.wide).year())
                Text(currency?.value ?? "")
                Text("budget.month_only_detail")
            }
        }
    }

    @ViewBuilder
    private var allocationPreview: some View {
        if let currency, trimmed.isEmpty || decimalAmount(from: trimmed) != nil {
            let amount = decimalAmount(from: trimmed) ?? .zero
            if let own = try? Money(amount, currency: currency),
               let total = mode == .automatic
                    ? try? own.adding(childAllocation ?? .zero(currency: currency)) : own {
                LabeledContent("budget.preview_total", value: formattedMoney(total))
                if mode == .fixedTotal, let childAllocation, childAllocation.amount > amount {
                    Label("budget.children_overallocated", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.moneyUpWarning)
                }
            }
        }
    }

    private func save() async {
        guard let currency, isValid else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.setMonthlyBudget(
                categoryID: node.id, date: asOf, currency: currency,
                amount: trimmed.isEmpty ? nil : decimalAmount(from: trimmed),
                mode: mode, purpose: purpose
            )
            dismiss()
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    private func changeMode(_ newMode: BudgetAllocationMode) {
        guard let currency else { return }
        do {
            guard trimmed.isEmpty || decimalAmount(from: trimmed) != nil else {
                throw MonthlyBudgetError.invalidAllocation
            }
            let own = try decimalAmount(from: trimmed).map { try Money($0, currency: currency) }
            let converted = try BudgetModeConversion.limit(own, children: childAllocation, from: mode, to: newMode)
            amountText = converted.map { editableAmount($0.amount) } ?? ""
            mode = newMode
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    private func useRecurring() async {
        guard let currency else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.useRecurringBudget(categoryID: node.id, date: asOf, currency: currency)
            dismiss()
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}

/// A suggested first split of one monthly figure across the starter
/// categories. Shares are whole multiples of five that add to 100, so every
/// row reads as a round number the person can nudge.
enum StarterBudgetSplit {
    struct Share: Equatable, Identifiable {
        let id: UUID
        let name: String
        var percent: Int
        let purpose: BudgetPurpose
    }

    static func suggested(for nodes: [BudgetNode]) -> [Share] {
        let open = nodes.filter { $0.limit == nil }
        let topLevel = open.filter { $0.parentID == nil }
        let candidates = Array((topLevel.isEmpty ? open : topLevel).prefix(6))
        guard !candidates.isEmpty else { return [] }
        let weights = candidates.map { weight(forName: $0.name) }
        let total = weights.reduce(0, +)
        var percents = weights.map { Int((Double($0) / Double(total) * 20).rounded()) * 5 }
        let drift = 100 - percents.reduce(0, +)
        if let largest = percents.indices.max(by: { percents[$0] < percents[$1] }) {
            percents[largest] = max(0, percents[largest] + drift)
        }
        return zip(candidates, percents).map { node, percent in
            Share(id: node.id, name: node.name, percent: percent,
                  purpose: isCommitment(node.name) ? .commitment : .flexible)
        }
        .sorted { $0.percent > $1.percent }
    }

    /// Whole-unit amount for a share; the remainder of rounding stays
    /// unallocated rather than inflating a row.
    static func amount(total: Decimal, percent: Int) -> Decimal {
        var raw = total * Decimal(percent) / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .down)
        return rounded
    }

    private static func weight(forName name: String) -> Int {
        if isCommitment(name) { return 40 }
        switch MoneyUpCategorySymbol.symbol(forName: name) {
        case "cart.fill", "fork.knife", "basket.fill", "bus.fill": return 35
        case "sparkles", "bag.fill", "film.fill": return 25
        default: return 15
        }
    }

    private static func isCommitment(_ name: String) -> Bool {
        ["house.fill", "bolt.fill", "wifi", "iphone", "shield.fill"]
            .contains(MoneyUpCategorySymbol.symbol(forName: name) ?? "")
    }
}

/// One screen from "no budget" to a working month: a single monthly figure,
/// a suggested split with ±5% steppers, and one Save.
struct StarterBudgetSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var totalText = ""
    @State private var shares: [StarterBudgetSplit.Share] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTotalFocused: Bool

    private var currency: CurrencyCode? { model.profile?.baseCurrency }
    private var total: Decimal? { decimalAmount(from: totalText).flatMap { $0 > 0 ? $0 : nil } }
    private var allocated: Int { shares.map(\.percent).reduce(0, +) }
    private var canSave: Bool { total != nil && allocated > 0 && allocated <= 100 && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        TextField(text: $totalText, prompt: Text(verbatim: "0")) {
                            Text("budget.setup.total")
                        }
                            .moneyAmountKeyboard(currency: currency)
                            .moneyUpFinancialValue(.hero)
                            .focused($isTotalFocused)
                        Text(currency?.value ?? "")
                            .font(.headline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("budget.setup.total")
                } footer: {
                    Text("budget.setup.total_hint")
                }
                Section {
                    ForEach($shares) { $share in
                        shareRow($share)
                    }
                } footer: {
                    allocationFooter
                }
            }
            .navigationTitle("budget.setup.title")
            .navigationBarTitleDisplayMode(.inline)
            .moneyUpNavigationSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
            .onAppear {
                if shares.isEmpty { shares = StarterBudgetSplit.suggested(for: model.budgetNodes) }
                isTotalFocused = true
            }
        }
    }

    private func shareRow(_ share: Binding<StarterBudgetSplit.Share>) -> some View {
        let value = share.wrappedValue
        return HStack(alignment: .top, spacing: 12) {
            MoneyUpCategoryBadge(
                systemImage: MoneyUpCategorySymbol.symbol(for: value.id, accountsByID: model.accountsByID),
                tint: MoneyUpCategorySymbol.tint(for: value.id),
                size: 34
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(value.name).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(amountText(for: value.percent))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                HStack(spacing: 8) {
                    Label(value.purpose.titleKey, systemImage: value.purpose.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text("\(value.percent)%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Stepper(value.name, value: share.percent, in: 0...100, step: 5)
                        .labelsHidden()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var allocationFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: allocated > 100 ? "exclamationmark.triangle.fill"
                : allocated == 100 ? "checkmark.circle.fill" : "circle.dashed")
            Text(String(format: AppLocalization.string("budget.setup.allocated"), allocated))
                .monospacedDigit()
        }
        .foregroundStyle(allocated > 100 ? Color.moneyUpDanger : allocated == 100 ? Color.moneyUpPositive : .secondary)
    }

    private func amountText(for percent: Int) -> String {
        guard let total, let currency,
              let money = try? Money(StarterBudgetSplit.amount(total: total, percent: percent), currency: currency)
        else { return "—" }
        return formattedMoney(money)
    }

    private func save() async {
        guard let total else { return }
        isSaving = true
        defer { isSaving = false }
        let limits = shares.filter { $0.percent > 0 }.map {
            (categoryID: $0.id, amount: StarterBudgetSplit.amount(total: total, percent: $0.percent), purpose: $0.purpose)
        }
        do {
            try await model.setStarterBudgetLimits(limits)
            // Flexible shares go straight onto Today so the next screen shows
            // what is left; pinning is a display preference and never blocks.
            if model.pinnedBudgetNodes.isEmpty {
                for share in shares where share.purpose == .flexible && share.percent > 0
                    && model.canPinAnotherBudgetNode {
                    try? await model.setBudgetNodePinned(share.id, isPinned: true)
                }
            }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
