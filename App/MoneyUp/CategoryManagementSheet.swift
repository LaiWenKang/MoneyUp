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

    private var category: LedgerAccount? { model.accountsByID[categoryID] }
    private var budget: BudgetNode? { model.budgetNodes.first { $0.id == categoryID } }
    private var hasChanges: Bool { isLoaded && (name != category?.name || parentID != category?.parentID) }
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
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        MoneyUpKeyboardDoneToolbar()
    }

    private func loadOnce() {
        guard !isLoaded, let category else { return }
        name = category.name
        parentID = category.parentID
        isLoaded = true
    }

    private func save() async {
        guard category != nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.updateCategoryMetadata(
                categoryID: categoryID, name: name, amount: budget?.limit?.amount,
                purpose: budget?.purpose ?? .unclassified,
                pacingCadence: budget?.pacingCadence ?? .monthly,
                rolloverRule: budget?.rolloverRule ?? .none, parentChange: .set(parentID)
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
}
