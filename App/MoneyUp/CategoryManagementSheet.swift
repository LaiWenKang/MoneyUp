import MoneyUpCore
import SwiftUI

struct CategoryManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let categoryID: UUID
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var isDiscarding = false
    @State private var isArchiving = false
    @State private var isEditingBudget = false
    @State private var lifecycleRequest: CategoryLifecycleRequest?
    @State private var errorMessage: String?
    @State private var recurringAmount = ""
    @State private var recurringPurpose: BudgetPurpose = .unclassified
    @State private var recurringMode: BudgetAllocationMode = .automatic
    @State private var recurringRollover: BudgetRolloverRule = .none
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @FocusState private var recurringAmountFocused: Bool

    private var category: LedgerAccount? { model.accountsByID[categoryID] }
    private var budget: BudgetNode? { model.budgetNodes.first { $0.id == categoryID } }
    private var hasChanges: Bool {
        isLoaded && (name != category?.name || parentID != category?.parentID || recurringHasChanges)
    }
    private var recurringHasChanges: Bool {
        recurringAmount != (budget?.limit.map { editableAmount($0.amount) } ?? "")
            || recurringPurpose != (budget?.purpose ?? .unclassified)
            || recurringMode != (budget?.allocationMode ?? .automatic)
            || recurringRollover != (budget?.rolloverRule ?? .none)
    }
    private var recurringIsValid: Bool {
        !recurringHasChanges || recurringAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (decimalAmount(from: recurringAmount).map { $0 >= .zero } == true && recurringPurpose != .unclassified)
    }
    private var recurringValidationMessage: String? {
        recurringIsValid ? nil : AppLocalization.string("budget.invalid_allocation")
    }
    private var progress: BudgetProgress? {
        model.budgetProgressThisMonthResult().value?.first { $0.node.id == categoryID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("lifecycle.name") {
                    TextField("category.name", text: $name)
                    Picker("category.parent", selection: $parentID) {
                        Text("category.no_parent").tag(UUID?.none)
                        ForEach(model.compatibleCategoryParents(for: categoryID)) { parent in
                            Text(model.categoryPathName(for: parent.id)).tag(Optional(parent.id))
                        }
                    }
                    if isLoaded, parentID != category?.parentID, category?.kind == .expense {
                        Text("category.move_budget_detail").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if category?.kind == .expense {
                    Section {
                        Button("budget.edit_monthly") { isEditingBudget = true }.disabled(progress == nil)
                        Toggle("display.category_daily_guidance", isOn: Binding(
                            get: { !model.displayPreferences.hiddenGuidanceCategoryIDs.contains(categoryID) },
                            set: { visible in
                                model.changeDisplayPreferences { $0.setGuidanceVisible(visible, for: categoryID) }
                            }
                        ))
                    }
                    recurringSection
                }
                Section {
                    Button(category?.isArchived == true ? "lifecycle.restore" : "lifecycle.archive") {
                        isArchiving = true
                    }
                    Button("lifecycle.merge") {
                        lifecycleRequest = .init(categoryID: categoryID, action: .merge)
                    }
                    Button("lifecycle.delete_category", role: .destructive) {
                        lifecycleRequest = .init(categoryID: categoryID, action: .delete)
                    }
                } header: { Text("lifecycle.manage") }
                footer: { Text("lifecycle.archive_budget_detail") }
            }
            .disabled(isSaving)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(category?.name ?? AppLocalization.string("lifecycle.manage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .onAppear { loadOnce() }
            .onChange(of: category == nil) { _, missing in if missing { dismiss() } }
            .confirmationDialog("draft.discard_title", isPresented: $isDiscarding, titleVisibility: .visible) {
                Button("draft.discard_changes", role: .destructive) { dismiss() }
                Button("draft.keep_editing", role: .cancel) {}
            }
            .confirmationDialog("lifecycle.confirm_title", isPresented: $isArchiving, titleVisibility: .visible) {
                Button(category?.isArchived == true ? "lifecycle.restore" : "lifecycle.archive") {
                    Task { await archive() }
                }
            } message: { Text("lifecycle.archive_budget_detail") }
            .sheet(item: $lifecycleRequest) { CategoryLifecycleReviewSheet(request: $0) }
            .sheet(isPresented: $isEditingBudget) {
                if let progress {
                    BudgetEditorSheet(node: progress.node, asOf: model.currentDateForUserAction(),
                                      currency: model.profile?.baseCurrency, childAllocation: progress.childAllocation)
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .interactiveDismissDisabled(hasChanges || isSaving)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("action.cancel") { if hasChanges { isDiscarding = true } else { dismiss() } }
                .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("action.save") { Task { await save() } }
                .disabled(isSaving || !recurringIsValid || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        MoneyUpKeyboardDoneToolbar()
    }

    private func loadOnce() {
        guard !isLoaded, let category else { return }
        name = category.name
        parentID = category.parentID
        recurringAmount = budget?.limit.map { editableAmount($0.amount) } ?? ""
        recurringPurpose = budget?.purpose ?? .unclassified
        recurringMode = budget?.allocationMode ?? .automatic
        recurringRollover = budget?.rolloverRule ?? .none
        isLoaded = true
    }

    private func save() async {
        guard category != nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.updateCategoryMetadata(
                categoryID: categoryID, name: name, amount: decimalAmount(from: recurringAmount),
                purpose: recurringPurpose,
                pacingCadence: budget?.pacingCadence ?? .monthly,
                rolloverRule: recurringRollover, parentChange: .set(parentID), allocationMode: recurringMode
            )
            dismiss()
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    private func archive() async {
        guard let category else { return }
        isSaving = true
        defer { isSaving = false }
        do { try await model.setLedgerItemArchived(id: categoryID, isArchived: !category.isArchived) }
        catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    private var recurringSection: some View {
        Section {
            DisclosureGroup("budget.recurring_settings") {
                TextField("budget.recurring_allocation", text: $recurringAmount)
                    .moneyAmountKeyboard(currency: model.profile?.baseCurrency)
                    .focused($recurringAmountFocused)
                    .moneyUpPrivateAmountInput(
                        masked: hidesAmounts && !recurringAmountFocused && !recurringAmount.isEmpty,
                        accessibilityLabel: Text("budget.recurring_allocation")
                    ) { recurringAmountFocused = true }
                    .moneyUpFieldValidation(recurringValidationMessage)
                if let recurringValidationMessage { MoneyUpFieldError(message: recurringValidationMessage) }
                Picker("plan.purpose", selection: $recurringPurpose) {
                    ForEach(BudgetPurpose.allCases, id: \.self) { Text($0.titleKey).tag($0) }
                }
                Picker("budget.allocation_mode", selection: Binding(get: { recurringMode }, set: { value in changeRecurringMode(value) })) {
                    Text("budget.mode.automatic").tag(BudgetAllocationMode.automatic)
                    Text("budget.mode.fixed_total").tag(BudgetAllocationMode.fixedTotal)
                }
                Picker("plan.rollover", selection: $recurringRollover) {
                    ForEach(BudgetRolloverRule.allCases, id: \.self) { Text($0.titleKey).tag($0) }
                }
                Text("budget.recurring_detail").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func changeRecurringMode(_ newMode: BudgetAllocationMode) {
        guard let currency = model.profile?.baseCurrency else { return }
        do {
            let text = recurringAmount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty || decimalAmount(from: text) != nil else { throw MonthlyBudgetError.invalidAllocation }
            let own = try decimalAmount(from: text).map { try Money($0, currency: currency) }
            let children = try BudgetTree(currency: currency, nodes: model.budgetNodes)
                .progress(directSpending: [:]).first { $0.node.id == categoryID }?.childAllocation
            let converted = try BudgetModeConversion.limit(own, children: children, from: recurringMode, to: newMode)
            recurringAmount = converted.map { editableAmount($0.amount) } ?? ""
            recurringMode = newMode
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}
