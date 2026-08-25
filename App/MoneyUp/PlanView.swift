import MoneyUpCore
import SwiftUI

struct PlanView: View {
    private enum Section: Hashable {
        case budget
        case calendar
    }

    @State private var selection: Section = .budget

    var body: some View {
        Group {
            switch selection {
            case .budget:
                BudgetPlanView()
            case .calendar:
                CalendarView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("tab.plan", selection: $selection) {
                Text("plan.budget").tag(Section.budget)
                Text("tab.calendar").tag(Section.calendar)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
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

    /// How far through the month we are, drawn on every bar so a number can be
    /// read as ahead or behind rather than just large.
    private var monthElapsed: Double {
        let calendar = Calendar.current
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

    private func progressByID() -> [UUID: BudgetProgress] {
        Dictionary(
            uniqueKeysWithValues: model.budgetProgressThisMonth().map { ($0.node.id, $0) }
        )
    }

    var body: some View {
        // Resolved once per update. Reading it inside the row loop recomputed
        // the whole budget tree for every category on screen.
        let progress = progressByID()
        let elapsed = monthElapsed
        let foreignSpending = model.excludedForeignSpendingThisMonth()

        return NavigationStack {
            List {
                if let summary = model.budgetPlanSummaryThisMonth() {
                    Section {
                        BudgetSummaryCard(
                            limit: summary.limit,
                            spent: summary.spent,
                            remaining: summary.remaining,
                            elapsed: elapsed
                        )
                    }
                }

                if !foreignSpending.isEmpty {
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
                }

                Section {
                    ForEach(orderedNodes) { item in
                        Button {
                            editingNode = item.node
                        } label: {
                            BudgetRow(
                                node: item.node,
                                depth: item.depth,
                                progress: progress[item.node.id],
                                elapsed: elapsed
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("plan.this_month")
                } footer: {
                    Text("plan.rollup_detail")
                }
            }
            .overlay {
                if model.budgetNodes.isEmpty {
                    ContentUnavailableView(
                        "plan.empty",
                        systemImage: "chart.pie",
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

/// A track showing spending against a limit, with a marker for how far
/// through the month we are. The marker is what turns "$420 of $600" into
/// "ahead" or "behind" without the reader doing the arithmetic.
private struct BudgetBar: View {
    let ratio: Double
    let elapsed: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))

                Capsule()
                    .fill(ratio > 1 ? Color.red : Color.accentColor)
                    .frame(width: proxy.size.width * min(max(ratio, 0), 1))

                Capsule()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 2)
                    .offset(x: proxy.size.width * min(max(elapsed, 0), 1) - 1)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

private struct BudgetRow: View {
    let node: BudgetNode
    let depth: Int
    let progress: BudgetProgress?
    let elapsed: Double

    private var spent: Money? { progress?.spent }

    private var ratio: Double? {
        guard let limit = node.limit?.amount,
              let spent = spent?.amount else { return nil }
        if limit == .zero { return spent > .zero ? 2 : 0 }
        guard limit > .zero else { return nil }
        return NSDecimalNumber(decimal: spent / limit).doubleValue
    }

    private var remaining: Money? { progress?.remaining }

    private var isOverspent: Bool {
        guard let remaining else { return false }
        return remaining.amount < .zero
    }

    var body: some View {
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

            if let ratio, let limit = node.limit, let spent {
                BudgetBar(ratio: ratio, elapsed: elapsed)
                Text(
                    String(
                        format: String(localized: "plan.spent_of_limit"),
                        formattedMoney(spent),
                        formattedMoney(limit)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var ratio: Double {
        guard limit.amount > .zero else { return spent.amount > .zero ? 2 : 0 }
        return NSDecimalNumber(decimal: spent.amount / limit.amount).doubleValue
    }

    private var isOverspent: Bool { remaining.amount < .zero }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isOverspent ? "plan.total_over" : "plan.total_left")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(formattedMoney(isOverspent ? remaining.negated : remaining))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(isOverspent ? Color.red : Color.primary)
                .contentTransition(.numericText())

            BudgetBar(ratio: ratio, elapsed: elapsed)

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
                editableAmount($0.amount)
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
