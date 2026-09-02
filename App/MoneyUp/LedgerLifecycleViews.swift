import Foundation
import MoneyUpCore
import SwiftUI

func impactSummary(_ impact: AppModel.LedgerItemLifecycleImpact) -> String {
    String(
        format: AppLocalization.string("lifecycle.impact_summary"),
        impact.transactionCount,
        impact.scheduleCount,
        impact.holdingCount,
        impact.childCount,
        impact.defaultReferenceCount,
        impact.draftReferenceCount,
        impact.hasConfiguredBudget ? 1 : 0
    )
}

struct CategoryManagementList: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var selectedCategoryID: UUID?
    @State private var categoryKindToAdd: LedgerAccountKind = .expense
    @State private var isAddingCategory = false

    private var expenseCategories: [LedgerAccount] {
        model.manageableLedgerItems
            .filter { $0.kind == .expense }
            .sorted(by: lifecycleSort)
    }

    private var incomeCategories: [LedgerAccount] {
        model.manageableLedgerItems
            .filter { $0.kind == .income }
            .sorted(by: lifecycleSort)
    }

    var body: some View {
        NavigationStack {
            List {
                categorySection(
                    title: "transaction.expense",
                    categories: expenseCategories
                )
                categorySection(
                    title: "transaction.income",
                    categories: incomeCategories
                )
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("lifecycle.manage_categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            categoryKindToAdd = .expense
                            isAddingCategory = true
                        } label: {
                            Label(
                                "lifecycle.add_expense_category",
                                systemImage: "minus.circle"
                            )
                        }
                        Button {
                            categoryKindToAdd = .income
                            isAddingCategory = true
                        } label: {
                            Label(
                                "lifecycle.add_income_category",
                                systemImage: "plus.circle"
                            )
                        }
                    } label: {
                        Label("category.add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { selectedCategoryID != nil },
                    set: { if !$0 { selectedCategoryID = nil } }
                )
            ) {
                if let selectedCategoryID {
                    CategoryManagementSheet(categoryID: selectedCategoryID)
                }
            }
            .sheet(isPresented: $isAddingCategory) {
                AddCategorySheet(kind: categoryKindToAdd)
            }
        }
    }

    @ViewBuilder
    private func categorySection(
        title: LocalizedStringKey,
        categories: [LedgerAccount]
    ) -> some View {
        Section(title) {
            ForEach(categories) { category in
                Button {
                    selectedCategoryID = category.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.categoryPathName(for: category.id))
                            if category.isArchived {
                                Text("lifecycle.archived")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: category.isArchived ? "archivebox.fill" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func lifecycleSort(_ lhs: LedgerAccount, _ rhs: LedgerAccount) -> Bool {
        if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

struct CategoryManagementSheet: View {
    private enum PendingLifecycleAction {
        case archive
        case restore
        case merge
        case deleteWithReassignment
        case deleteUnused
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @FocusState private var amountFocused: Bool
    let categoryID: UUID

    @State private var name = ""
    @State private var amountText = ""
    @State private var purpose: BudgetPurpose = .unclassified
    @State private var rolloverRule: BudgetRolloverRule = .none
    @State private var pacingCadence: BudgetPacingCadence = .monthly
    @State private var parentID: UUID?
    @State private var targetID: UUID?
    @State private var pendingLifecycleAction: PendingLifecycleAction?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var category: LedgerAccount? {
        model.accounts.first { $0.id == categoryID }
    }

    private var budgetNode: BudgetNode? {
        model.budgetNodes.first { $0.id == categoryID }
    }

    private var targets: [LedgerAccount] {
        model.compatibleLifecycleTargets(for: categoryID)
    }

    private var impact: AppModel.LedgerItemLifecycleImpact {
        model.lifecycleImpact(for: categoryID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("lifecycle.name") {
                    TextField("category.name", text: $name)
                    Picker("category.parent", selection: $parentID) {
                        Text("category.no_parent").tag(UUID?.none)
                        ForEach(model.compatibleCategoryParents(for: categoryID)) { parent in
                            Text(model.categoryPathName(for: parent.id))
                                .tag(Optional(parent.id))
                        }
                    }
                }

                if category?.kind == .expense {
                    Section {
                        TextField("quick_log.amount", text: $amountText)
                            .moneyAmountKeyboard(currency: model.profile?.baseCurrency)
                            .focused($amountFocused)
                        Picker("plan.purpose", selection: $purpose) {
                            ForEach(BudgetPurpose.allCases, id: \.self) { option in
                                Label(option.titleKey, systemImage: option.systemImage)
                                    .tag(option)
                            }
                        }
                        Picker("plan.rollover", selection: $rolloverRule) {
                            ForEach(BudgetRolloverRule.allCases, id: \.self) { rule in
                                Text(rule.titleKey).tag(rule)
                            }
                        }
                        if purpose == .flexible {
                            Picker("plan.pacing", selection: $pacingCadence) {
                                ForEach(BudgetPacingCadence.allCases, id: \.self) { cadence in
                                    Text(cadence.titleKey).tag(cadence)
                                }
                            }
                        }
                    } header: {
                        Text("plan.monthly_limit")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("plan.blank_removes_limit")
                            Text("plan.rollover_detail")
                        }
                    }
                }

                Section {
                    Button {
                        pendingLifecycleAction = category?.isArchived == true
                            ? .restore : .archive
                    } label: {
                        Label {
                            Text(
                                category?.isArchived == true
                                    ? LocalizedStringKey("lifecycle.restore")
                                    : LocalizedStringKey("lifecycle.archive")
                            )
                        } icon: {
                            Image(
                                systemName: category?.isArchived == true
                                    ? "arrow.uturn.backward.circle" : "archivebox"
                            )
                        }
                    }

                    if !targets.isEmpty {
                        Picker("lifecycle.destination", selection: $targetID) {
                            ForEach(targets) { target in
                                Text(target.name).tag(Optional(target.id))
                            }
                        }
                        Button {
                            pendingLifecycleAction = .merge
                        } label: {
                            Label("lifecycle.merge", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(targetID == nil)
                        Button(role: .destructive) {
                            pendingLifecycleAction = .deleteWithReassignment
                        } label: {
                            Label("lifecycle.delete_reassign", systemImage: "trash.slash")
                        }
                        .disabled(targetID == nil)
                    }

                    if impact.isUnused {
                        Button(role: .destructive) {
                            pendingLifecycleAction = .deleteUnused
                        } label: {
                            Label("lifecycle.delete_unused", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("lifecycle.manage")
                } footer: {
                    Text(impactSummary(impact))
                }

            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(category?.name ?? AppLocalization.string("lifecycle.manage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await saveMetadata() } }
                        .disabled(
                            isSaving
                                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || (!amountText.isEmpty && decimalAmount(from: amountText) == nil)
                                || (!amountText.isEmpty && purpose == .unclassified)
                        )
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("action.done") { amountFocused = false }
                }
            }
            .onAppear {
                guard let category else { return }
                name = category.name
                amountText = budgetNode?.limit.map { editableAmount($0.amount) } ?? ""
                purpose = budgetNode?.purpose ?? .unclassified
                rolloverRule = budgetNode?.rolloverRule ?? .none
                pacingCadence = budgetNode?.pacingCadence ?? .monthly
                parentID = category.parentID
                targetID = targets.first?.id
            }
            .confirmationDialog(
                "lifecycle.confirm_title",
                isPresented: Binding(
                    get: { pendingLifecycleAction != nil },
                    set: { if !$0 { pendingLifecycleAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(confirmButtonTitle, role: confirmButtonRole) {
                    Task { await performLifecycleAction() }
                }
                Button("action.cancel", role: .cancel) {
                    pendingLifecycleAction = nil
                }
            } message: {
                Text(confirmMessage)
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func saveMetadata() async {
        guard let category else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.updateCategoryMetadata(
                categoryID: categoryID,
                name: name,
                amount: category.kind == .expense && !trimmed.isEmpty
                    ? decimalAmount(from: trimmed) : nil,
                purpose: category.kind == .expense ? purpose : .unclassified,
                pacingCadence: category.kind == .expense && purpose == .flexible
                    ? pacingCadence : .monthly,
                rolloverRule: category.kind == .expense ? rolloverRule : .none
            )
            if category.parentID != parentID {
                try await model.reparentCategory(id: categoryID, parentID: parentID)
            }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private var confirmButtonTitle: LocalizedStringKey {
        switch pendingLifecycleAction {
        case .archive: "lifecycle.archive"
        case .restore: "lifecycle.restore"
        case .merge: "lifecycle.merge"
        case .deleteWithReassignment: "lifecycle.delete_reassign"
        case .deleteUnused: "lifecycle.delete_unused"
        case nil: "action.okay"
        }
    }

    private var confirmButtonRole: ButtonRole? {
        switch pendingLifecycleAction {
        case .deleteWithReassignment, .deleteUnused: .destructive
        default: nil
        }
    }

    private var confirmMessage: String {
        let base = impactSummary(impact)
        switch pendingLifecycleAction {
        case .archive:
            return AppLocalization.string("lifecycle.confirm_archive") + " " + base
        case .restore:
            return AppLocalization.string("lifecycle.confirm_restore")
        case .merge:
            return AppLocalization.string("lifecycle.confirm_merge") + " " + base
        case .deleteWithReassignment:
            return AppLocalization.string("lifecycle.confirm_reassign") + " " + base
        case .deleteUnused:
            return AppLocalization.string("lifecycle.confirm_delete")
        case nil:
            return ""
        }
    }

    private func performLifecycleAction() async {
        let action = pendingLifecycleAction
        pendingLifecycleAction = nil
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            switch action {
            case .archive:
                try await model.setLedgerItemArchived(id: categoryID, isArchived: true)
            case .restore:
                try await model.setLedgerItemArchived(id: categoryID, isArchived: false)
            case .merge:
                guard let targetID else { return }
                try await model.mergeLedgerItem(id: categoryID, into: targetID)
                dismiss()
            case .deleteWithReassignment:
                guard let targetID else { return }
                try await model.deleteLedgerItem(
                    id: categoryID,
                    reassigningTo: targetID
                )
                dismiss()
            case .deleteUnused:
                try await model.deleteLedgerItem(id: categoryID)
                dismiss()
            case nil:
                return
            }
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
