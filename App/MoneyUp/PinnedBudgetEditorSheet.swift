import MoneyUpCore
import SwiftUI

/// Chooses which budget categories appear on the Today board.
///
/// Pins are applied one at a time so the board never shows a set the book has
/// not actually stored, and a rejected write leaves the visible state matching
/// the profile rather than an optimistic guess.
struct PinnedBudgetEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var pendingNodeID: UUID?

    private var pinnedCount: Int {
        model.profile?.pinnedBudgetNodeIDs.count ?? 0
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.budgetNodeOutline.isEmpty {
                        ContentUnavailableView(
                            "today.pinned.needs_budget",
                            systemImage: "chart.pie",
                            description: Text("today.pinned.needs_budget_detail")
                        )
                    } else {
                        ForEach(model.budgetNodeOutline) { outlined in
                            row(for: outlined)
                        }
                    }
                } header: {
                    Text("today.pinned.editor_categories")
                } footer: {
                    Text(
                        String(
                            format: AppLocalization.string("today.pinned.editor_count_format"),
                            pinnedCount,
                            UserProfile.maximumPinnedBudgetNodes
                        )
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("today.pinned.editor_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func row(for outlined: OutlinedBudgetNode) -> some View {
        let isPinned = model.isBudgetNodePinned(outlined.node.id)
        let isDisabled = pendingNodeID != nil
            || (!isPinned && !model.canPinAnotherBudgetNode)
        return Button {
            Task { await toggle(outlined.node, isPinned: isPinned) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outlined.node.name)
                    if let limit = outlined.node.limit {
                        Text(formattedMoney(limit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("today.pinned.no_limit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if pendingNodeID == outlined.node.id { ProgressView() }
            }
            .padding(.leading, CGFloat(min(outlined.depth, 4)) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isPinned ? .isSelected : [])
    }

    private func toggle(_ node: BudgetNode, isPinned: Bool) async {
        pendingNodeID = node.id
        defer { pendingNodeID = nil }
        do {
            try await model.setBudgetNodePinned(node.id, isPinned: !isPinned)
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
