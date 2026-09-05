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
                        Picker("budget.allocation_mode", selection: Binding(get: { mode }, set: changeMode)) {
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
                        .foregroundStyle(.orange)
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
