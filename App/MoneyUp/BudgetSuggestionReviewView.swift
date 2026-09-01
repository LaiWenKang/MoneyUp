import MoneyUpCore
import MoneyUpIntelligence
import SwiftUI

struct BudgetSuggestionReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var result: DerivedValue<[BudgetLimitSuggestion]>?
    @State private var selectedIDs = Set<UUID>()
    @State private var undoPatch: BudgetSuggestionPatch?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Label(
                    "intelligence.budget.private_detail",
                    systemImage: "lock.shield.fill"
                )
                .font(.subheadline)
            }
            suggestionContent
            if undoPatch != nil {
                Section {
                    Label(
                        "intelligence.budget.applied",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Button("intelligence.budget.undo") {
                        Task { await undo() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .navigationTitle("intelligence.budget.review_title")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("intelligence.budget.apply") {
                    Task { await apply() }
                }
                .disabled(selectedIDs.isEmpty || undoPatch != nil || isSaving)
            }
        }
        .task { await load() }
        .alert(
            "error.could_not_save",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("action.okay", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var suggestionContent: some View {
        switch result {
        case .none:
            Section { ProgressView().frame(maxWidth: .infinity) }
        case let .some(.available(suggestions)):
            if suggestions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "intelligence.budget.empty",
                        systemImage: "checkmark.circle",
                        description: Text("intelligence.budget.empty_detail")
                    )
                }
            } else {
                Section("intelligence.budget.review_detail") {
                    ForEach(suggestions, id: \.categoryID) { suggestion in
                        suggestionRow(suggestion)
                    }
                } footer: {
                    Text("intelligence.budget.apply_detail")
                }
            }
        case let .some(.unavailable(issue)):
            Section { DerivedValueUnavailableView(issue: issue) }
        }
    }

    private func suggestionRow(
        _ suggestion: BudgetLimitSuggestion
    ) -> some View {
        Button {
            toggle(suggestion.categoryID)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedIDs.contains(suggestion.categoryID)
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(categoryName(suggestion.categoryID))
                        .font(.headline)
                    Text(limitChange(suggestion))
                        .font(.subheadline.monospacedDigit())
                    Text(evidence(suggestion))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(undoPatch != nil || isSaving)
    }

    private func categoryName(_ id: UUID) -> String {
        model.budgetNodes.first(where: { $0.id == id })?.name
            ?? AppLocalization.string("category.unknown")
    }

    private func limitChange(_ suggestion: BudgetLimitSuggestion) -> String {
        let current = suggestion.currentLimit.map(formattedMoney)
            ?? AppLocalization.string("intelligence.budget.no_limit")
        return String(
            format: AppLocalization.string("intelligence.budget.change_format"),
            current,
            formattedMoney(suggestion.proposedLimit)
        )
    }

    private func evidence(_ suggestion: BudgetLimitSuggestion) -> String {
        String(
            format: AppLocalization.string("intelligence.budget.evidence_format"),
            formattedMoney(suggestion.median),
            formattedMoney(suggestion.medianAbsoluteDeviation),
            suggestion.sampleSize,
            suggestion.ruleID
        )
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    @MainActor
    private func load() async {
        result = nil
        let loaded = await model.budgetLimitSuggestionsResult()
        result = loaded
        if case let .available(suggestions) = loaded {
            selectedIDs = Set(suggestions.map(\.categoryID))
        }
    }

    @MainActor
    private func apply() async {
        guard case let .some(.available(suggestions)) = result else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            undoPatch = try await model.applyBudgetSuggestions(
                suggestions.filter { selectedIDs.contains($0.categoryID) }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func undo() async {
        guard let undoPatch else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.undoBudgetSuggestionPatch(undoPatch)
            self.undoPatch = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
