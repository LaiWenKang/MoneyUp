import MoneyUpCore
import SwiftUI

struct PlanView: View {
    private struct IndentedNode: Identifiable {
        let node: BudgetNode
        let depth: Int
        var id: UUID { node.id }
    }

    @EnvironmentObject private var model: AppModel
    @State private var editingNode: BudgetNode?
    @State private var isAddingCategory = false

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

    private var progressByID: [UUID: BudgetProgress] {
        Dictionary(uniqueKeysWithValues: model.budgetProgressThisMonth().map { ($0.node.id, $0) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("plan.rollup_detail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("plan.this_month") {
                    ForEach(orderedNodes) { item in
                        Button {
                            editingNode = item.node
                        } label: {
                            BudgetRow(
                                node: item.node,
                                depth: item.depth,
                                progress: progressByID[item.node.id]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if model.budgetNodes.isEmpty {
                    ContentUnavailableView(
                        "plan.empty",
                        systemImage: "target",
                        description: Text("plan.empty_detail")
                    )
                }
            }
            .navigationTitle("tab.plan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingCategory = true
                    } label: {
                        Label("category.add", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editingNode) { node in
                BudgetEditorSheet(node: node)
            }
            .sheet(isPresented: $isAddingCategory) {
                AddCategorySheet()
            }
        }
    }
}

private struct BudgetRow: View {
    let node: BudgetNode
    let depth: Int
    let progress: BudgetProgress?

    private var ratio: Double? {
        guard let limit = node.limit?.amount, limit > .zero,
              let spent = progress?.spent.amount else { return nil }
        return min(max(NSDecimalNumber(decimal: spent / limit).doubleValue, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(min(depth, 4)) * 10)
                }
                Text(node.name)
                    .fontWeight(depth == 0 ? .semibold : .regular)
                Spacer()
                if let spent = progress?.spent {
                    Text(formattedMoney(spent))
                        .font(.subheadline.monospacedDigit())
                }
            }
            if let ratio, let limit = node.limit {
                ProgressView(value: ratio)
                    .tint(ratio >= 1 ? .red : .accentColor)
                HStack {
                    Text("plan.limit")
                    Spacer()
                    Text(formattedMoney(limit))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("plan.tap_to_set_limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct BudgetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let node: BudgetNode

    @State private var amountText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(node: BudgetNode) {
        self.node = node
        _amountText = State(
            initialValue: node.limit.map {
                NSDecimalNumber(decimal: $0.amount).stringValue
            } ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("quick_log.amount", text: $amountText)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("plan.monthly_limit")
                } footer: {
                    Text("plan.blank_removes_limit")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(node.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(isSaving || (!amountText.isEmpty && decimalAmount(from: amountText) == nil))
                }
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
                amount: trimmed.isEmpty ? nil : decimalAmount(from: trimmed)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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

    var body: some View {
        NavigationStack {
            Form {
                TextField("category.name", text: $name)
                Picker("category.parent", selection: $parentID) {
                    Text("category.no_parent").tag(UUID?.none)
                    ForEach(model.expenseCategories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("category.add")
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
            try await model.addCategory(name: name, kind: .expense, parentID: parentID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
