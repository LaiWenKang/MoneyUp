import MoneyUpCore
import SwiftUI

struct CategoryBudgetImpact: Identifiable {
    let currency: CurrencyCode
    let before: Money
    let after: Money
    var id: CurrencyCode { currency }
}

extension AppModel {
    func categoryBudgetImpact(sourceID: UUID, targetID: UUID) throws -> [CategoryBudgetImpact] {
        let (source, target) = try validatedLedgerReassignmentEndpoints(sourceID: sourceID, targetID: targetID)
        guard source.kind == .expense else { return [] }
        let candidateAccounts = try accountsAfterReassigningCategoryHierarchy(source: source, target: target)
        let candidateNodes = try budgetsAfterReassigningCategoryHierarchy(
            source: source, target: target, candidateAccounts: candidateAccounts
        )
        let month = try BudgetMonth(containing: currentDateForUserAction(), calendar: reportingCalendar)
        return try budgetCurrencies.map { currency in
            let before = try BudgetTree(currency: currency, nodes: budgetNodes, month: month)
                .planSummary(directSpending: [:])?.limit ?? .zero(currency: currency)
            let after = try BudgetTree(currency: currency, nodes: candidateNodes, month: month)
                .planSummary(directSpending: [:])?.limit ?? .zero(currency: currency)
            return CategoryBudgetImpact(currency: currency, before: before, after: after)
        }
    }
}

struct CategoryLifecycleReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let request: CategoryLifecycleRequest
    @State private var targetID: UUID?
    @State private var isAddingDestination = false
    @State private var isSaving = false
    @State private var preview: [CategoryBudgetImpact] = []
    @State private var isPreviewValid = false
    @State private var errorMessage: String?

    private var category: LedgerAccount? { model.accountsByID[request.categoryID] }
    private var impact: AppModel.LedgerItemLifecycleImpact { model.lifecycleImpact(for: request.categoryID) }
    private var needsDestination: Bool { request.action == .merge || !impact.canDeleteWithoutReassignment }
    private var targets: [LedgerAccount] { model.compatibleLifecycleTargets(for: request.categoryID) }
    private var title: LocalizedStringKey {
        request.action == .merge ? "lifecycle.merge" : "lifecycle.delete_category"
    }
    private var previewIdentity: String {
        "\(targetID?.uuidString ?? "")-\(model.budgetNodesRevision)-\(model.journalProjectionRevision)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("category.name", value: category?.name ?? "")
                    Text(impactSummary(impact))
                    Text("lifecycle.history_preserved")
                }
                if needsDestination { destinationSection }
                if model.planningReferenceCount(to: request.categoryID) > 0 {
                    Section { Label("lifecycle.planning_reference_review", systemImage: "exclamationmark.triangle") }
                }
                if !impact.transactionReferencesAreCurrent {
                    Section { ProgressView("lifecycle.checking_references") }
                }
                if targetID != nil && !isPreviewValid {
                    Section { Label("lifecycle.review_blocked", systemImage: "exclamationmark.triangle") }
                } else if !preview.isEmpty {
                    Section {
                        ForEach(preview) { item in
                            LabeledContent(item.currency.value) {
                                Text("\(formattedMoney(item.before)) → \(formattedMoney(item.after))")
                                    .monospacedDigit()
                            }
                        }
                        Text("lifecycle.merge_budget_detail")
                    } header: { Text("lifecycle.budget_impact") }
                }
                Section {
                    Button(title, role: request.action == .delete ? .destructive : nil) {
                        Task { await commit() }
                    }
                    .disabled(isSaving || !impact.transactionReferencesAreCurrent
                        || (needsDestination && targetID == nil) || (needsDestination && !isPreviewValid)
                        || model.planningReferenceCount(to: request.categoryID) > 0)
                } footer: {
                    Text(needsDestination ? "lifecycle.reassignment_confirmation" : "lifecycle.unused_delete_confirmation")
                }
            }
            .disabled(isSaving)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }.disabled(isSaving)
                }
            }
            .task(id: previewIdentity) { updatePreview() }
            .sheet(isPresented: $isAddingDestination) {
                AddCategorySheet(kind: category?.kind ?? .expense) { targetID = $0 }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var destinationSection: some View {
        Section {
            Picker("lifecycle.destination", selection: $targetID) {
                Text("lifecycle.choose_destination").tag(UUID?.none)
                ForEach(targets) { target in
                    Text(model.categoryPathName(for: target.id)).tag(Optional(target.id))
                }
            }
            Button("lifecycle.create_destination") { isAddingDestination = true }
        } footer: { Text("lifecycle.destination_detail") }
    }

    private func updatePreview() {
        preview = []
        isPreviewValid = false
        guard let targetID else { return }
        do {
            preview = try model.categoryBudgetImpact(sourceID: request.categoryID, targetID: targetID)
            isPreviewValid = true
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    private func commit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if request.action == .merge, let targetID {
                try await model.mergeLedgerItem(id: request.categoryID, into: targetID)
            } else {
                try await model.deleteLedgerItem(id: request.categoryID, reassigningTo: targetID)
            }
            dismiss()
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}
