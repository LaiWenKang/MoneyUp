import MoneyUpCore
import SwiftUI

struct CategoryLifecycleRequest: Identifiable {
    enum Action { case merge, delete }
    let categoryID: UUID
    let action: Action
    let id = UUID()
}

struct CategoryManagementList: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var selectedCategory: LedgerAccount?
    @State private var lifecycleRequest: CategoryLifecycleRequest?
    @State private var categoryKindToAdd: LedgerAccountKind = .expense
    @State private var parentIDToAdd: UUID?
    @State private var isAddingCategory = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                categorySection(kind: .expense, title: "transaction.expense")
                categorySection(kind: .income, title: "transaction.income")
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .searchable(text: $searchText, prompt: "lifecycle.search_categories")
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("lifecycle.manage_categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("lifecycle.add_expense_category") { add(kind: .expense) }
                        Button("lifecycle.add_income_category") { add(kind: .income) }
                    } label: { Label("category.add", systemImage: "plus") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } }
            }
            .sheet(item: $selectedCategory) { CategoryManagementSheet(categoryID: $0.id) }
            .sheet(item: $lifecycleRequest) { CategoryLifecycleReviewSheet(request: $0) }
            .sheet(isPresented: $isAddingCategory) {
                AddCategorySheet(kind: categoryKindToAdd, initialParentID: parentIDToAdd)
            }
        }
    }

    private func add(kind: LedgerAccountKind, parentID: UUID? = nil) {
        categoryKindToAdd = kind
        parentIDToAdd = parentID
        isAddingCategory = true
    }

    private func outline(kind: LedgerAccountKind) -> [BudgetOutlineItem] {
        let categories = model.manageableLedgerItems.filter { $0.kind == kind }
        let nodes = categories.map { BudgetNode(id: $0.id, parentID: $0.parentID, name: $0.name) }
        let outline = BudgetOutline.items(nodes)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return outline }
        let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parentID) })
        var retained = Set<UUID>()
        for item in outline where model.categoryPathName(for: item.id).localizedCaseInsensitiveContains(query) {
            var cursor: UUID? = item.id
            while let id = cursor, retained.insert(id).inserted { cursor = parents[id] ?? nil }
        }
        return outline.filter { retained.contains($0.id) }
    }

    private func categorySection(kind: LedgerAccountKind, title: LocalizedStringKey) -> some View {
        Section(title) {
            ForEach(outline(kind: kind)) { item in
                if let category = model.accountsByID[item.id] {
                    HStack(spacing: 8) {
                        Button { selectedCategory = category } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.name).fontWeight(item.depth == 0 ? .semibold : .regular)
                                if category.isArchived {
                                    Label("lifecycle.archived", systemImage: "archivebox").font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button("lifecycle.manage") { selectedCategory = category }
                            if !category.isArchived {
                                Button("lifecycle.add_subcategory") { add(kind: kind, parentID: category.id) }
                            }
                            Button("lifecycle.merge") {
                                lifecycleRequest = .init(categoryID: category.id, action: .merge)
                            }
                            Button("lifecycle.delete_category", role: .destructive) {
                                lifecycleRequest = .init(categoryID: category.id, action: .delete)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(String(format: AppLocalization.string("lifecycle.actions_for"), category.name))
                    }
                    .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }
}
