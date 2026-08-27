import MoneyUpCore
import SwiftUI

struct SavingsGoalsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAddingGoal = false
    @State private var selectedGoalID: UUID?

    private var activeGoals: [SavingsGoal] {
        model.savingsGoals.filter { !$0.isArchived }
    }

    private var archivedGoals: [SavingsGoal] {
        model.savingsGoals.filter(\.isArchived)
    }

    var body: some View {
        NavigationStack {
            List {
                if !activeGoals.isEmpty {
                    Section("goal.active") {
                        ForEach(activeGoals) { goal in
                            goalButton(goal)
                        }
                    }
                }
                if !archivedGoals.isEmpty {
                    Section("goal.archived") {
                        ForEach(archivedGoals) { goal in
                            goalButton(goal)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .overlay {
                if model.savingsGoals.isEmpty {
                    ContentUnavailableView {
                        Label("goal.empty", systemImage: "target")
                    } description: {
                        Text("goal.empty_detail")
                    } actions: {
                        Button("goal.add") { isAddingGoal = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.moneyUpAction)
                    }
                }
            }
            .navigationTitle("plan.goals")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingGoal = true
                    } label: {
                        Label("goal.add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingGoal) {
                GoalEditorSheet()
            }
            .sheet(
                isPresented: Binding(
                    get: { selectedGoalID != nil },
                    set: { if !$0 { selectedGoalID = nil } }
                )
            ) {
                if let selectedGoalID {
                    GoalManagementSheet(goalID: selectedGoalID)
                }
            }
        }
    }

    private func goalButton(_ goal: SavingsGoal) -> some View {
        Button { selectedGoalID = goal.id } label: {
            GoalProgressRow(goal: goal)
        }
        .buttonStyle(.plain)
    }
}

private struct GoalProgressRow: View {
    @EnvironmentObject private var model: AppModel
    let goal: SavingsGoal

    private var summary: DerivedValue<SavingsGoalSummary> {
        model.savingsGoalSummary(goal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(goal.name, systemImage: goal.kind.systemImage)
                    .font(.headline)
                Spacer()
                if goal.isArchived {
                    Text("goal.archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch summary {
            case let .available(summary):
                let progress = NSDecimalNumber(decimal: summary.progress).doubleValue
                let isOverdue = summary.isPastDue
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(summary.isComplete ? .moneyUpAction : .accentColor)
                    .accessibilityHidden(true)
                HStack {
                    Text(
                        String(
                            format: String(localized: "goal.progress_amount"),
                            formattedMoney(summary.balance),
                            formattedMoney(summary.target)
                        )
                    )
                    .font(.caption.monospacedDigit())
                    Spacer()
                    Label {
                        Text(
                            summary.isComplete
                                ? LocalizedStringKey("goal.complete")
                                : (isOverdue
                                    ? LocalizedStringKey("goal.overdue")
                                    : LocalizedStringKey("goal.in_progress"))
                        )
                    } icon: {
                        Image(
                            systemName: summary.isComplete
                                ? "checkmark.circle.fill"
                                : (isOverdue ? "exclamationmark.triangle.fill" : "clock")
                        )
                    }
                    .font(.caption.weight(.semibold))
                }
                Text(goal.targetDate, format: .dateTime.year().month().day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case let .unavailable(issue):
                DerivedValueUnavailableView(issue: issue)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("goal.manage_hint")
    }
}

private struct GoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FocusState private var amountFocused: Bool

    @State private var name = ""
    @State private var kind: SavingsGoalKind = .savingsGoal
    @State private var targetText = ""
    @State private var targetDate = Calendar.current.date(
        byAdding: .year,
        value: 1,
        to: Date()
    ) ?? Date()
    @State private var resetRule: SavingsGoalResetRule = .never
    @State private var currency: CurrencyCode?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var availableCurrencies: [CurrencyCode] {
        var values = Set(model.userAccounts.compactMap(\.currency))
        if let base = model.profile?.baseCurrency { values.insert(base) }
        return values.sorted()
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (decimalAmount(from: targetText) ?? .zero) > .zero
            && currency != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("goal.identity") {
                    TextField("goal.name", text: $name)
                    Picker("goal.kind", selection: $kind) {
                        ForEach(SavingsGoalKind.allCases, id: \.self) { option in
                            Label(option.titleKey, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                }
                Section("goal.target") {
                    TextField("goal.target_amount", text: $targetText)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                    Picker("goal.currency", selection: $currency) {
                        ForEach(availableCurrencies, id: \.self) { value in
                            Text(value.value).tag(Optional(value))
                        }
                    }
                    DatePicker(
                        "goal.target_date",
                        selection: $targetDate,
                        displayedComponents: .date
                    )
                }
                Section {
                    Picker("goal.reset_rule", selection: $resetRule) {
                        ForEach(SavingsGoalResetRule.allCases, id: \.self) { rule in
                            Text(rule.titleKey).tag(rule)
                        }
                    }
                } footer: {
                    Text("goal.reset_rule_detail")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("goal.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("action.done") { amountFocused = false }
                }
            }
            .onAppear { currency = currency ?? availableCurrencies.first }
        }
    }

    private func save() async {
        guard let amount = decimalAmount(from: targetText), let currency else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let createdAt = Date()
            let normalizedTargetDate = model.reportingCalendar.date(
                byAdding: .day,
                value: 1,
                to: model.reportingCalendar.startOfDay(for: targetDate)
            )?.addingTimeInterval(-1) ?? targetDate
            let goal = try SavingsGoal(
                name: name,
                kind: kind,
                target: try Money(amount, currency: currency),
                targetDate: normalizedTargetDate,
                resetRule: resetRule,
                createdAt: createdAt,
                reportingTimeZoneIdentifier: model.profile?.reportingTimeZoneIdentifier
                    ?? TimeZone.current.identifier
            )
            try await model.addSavingsGoal(goal)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GoalManagementSheet: View {
    private enum PendingAction: Equatable { case reset, delete }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FocusState private var amountFocused: Bool
    let goalID: UUID

    @State private var name = ""
    @State private var kind: SavingsGoalKind = .savingsGoal
    @State private var targetText = ""
    @State private var targetDate = Date()
    @State private var resetRule: SavingsGoalResetRule = .never
    @State private var movementKind: SavingsGoalMovementKind?
    @State private var pendingAction: PendingAction?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var goal: SavingsGoal? {
        model.savingsGoals.first { $0.id == goalID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let goal {
                    switch model.savingsGoalSummary(goal) {
                    case let .available(summary):
                        Section("goal.progress") {
                            LabeledContent("goal.balance", value: formattedMoney(summary.balance))
                            LabeledContent("goal.contributed", value: formattedMoney(summary.contributed))
                            LabeledContent("goal.withdrawn", value: formattedMoney(summary.withdrawn))
                            LabeledContent("goal.remaining", value: formattedMoney(summary.remaining))
                        }
                    case let .unavailable(issue):
                        Section("goal.progress") {
                            DerivedValueUnavailableView(issue: issue)
                        }
                    }
                }

                Section("goal.identity") {
                    TextField("goal.name", text: $name)
                    Picker("goal.kind", selection: $kind) {
                        ForEach(SavingsGoalKind.allCases, id: \.self) { option in
                            Label(option.titleKey, systemImage: option.systemImage).tag(option)
                        }
                    }
                }
                Section("goal.target") {
                    TextField("goal.target_amount", text: $targetText)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                    LabeledContent("goal.currency", value: goal?.target.currency.value ?? "—")
                    DatePicker(
                        "goal.target_date",
                        selection: $targetDate,
                        displayedComponents: .date
                    )
                    Picker("goal.reset_rule", selection: $resetRule) {
                        ForEach(SavingsGoalResetRule.allCases, id: \.self) { rule in
                            Text(rule.titleKey).tag(rule)
                        }
                    }
                }

                Section {
                    Button {
                        movementKind = .contribution
                    } label: {
                        Label("goal.contribute", systemImage: "plus.circle.fill")
                    }
                    Button {
                        movementKind = .withdrawal
                    } label: {
                        Label("goal.withdraw", systemImage: "minus.circle.fill")
                    }
                } header: {
                    Text("goal.movements")
                } footer: {
                    Text("goal.movements_detail")
                }

                Section("goal.manage") {
                    Button {
                        pendingAction = .reset
                    } label: {
                        Label("goal.reset_now", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        Task { await toggleArchive() }
                    } label: {
                        Label {
                            Text(
                                goal?.isArchived == true
                                    ? LocalizedStringKey("lifecycle.restore")
                                    : LocalizedStringKey("lifecycle.archive")
                            )
                        } icon: {
                            Image(
                                systemName: goal?.isArchived == true
                                    ? "arrow.uturn.backward.circle" : "archivebox"
                            )
                        }
                    }
                    Button(role: .destructive) {
                        pendingAction = .delete
                    } label: {
                        Label("action.delete", systemImage: "trash")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(goal?.name ?? String(localized: "plan.goals"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await saveMetadata() } }
                        .disabled(isSaving || name.isEmpty || decimalAmount(from: targetText) == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("action.done") { amountFocused = false }
                }
            }
            .onAppear { load() }
            .sheet(item: $movementKind) { movementKind in
                GoalMovementSheet(goalID: goalID, kind: movementKind)
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { pendingAction != nil },
                    set: { if !$0 { pendingAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if pendingAction == .delete {
                    Button("action.delete", role: .destructive) {
                        Task { await deleteGoal() }
                    }
                } else {
                    Button("goal.reset_now", role: .destructive) {
                        Task { await resetGoal() }
                    }
                }
                Button("action.cancel", role: .cancel) { pendingAction = nil }
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    private func load() {
        guard let goal else { return }
        name = goal.name
        kind = goal.kind
        targetText = editableAmount(goal.target.amount)
        targetDate = goal.targetDate
        resetRule = goal.resetRule
    }

    private var confirmationTitle: LocalizedStringKey {
        pendingAction == .delete ? "goal.delete_title" : "goal.reset_title"
    }

    private var confirmationMessage: LocalizedStringKey {
        pendingAction == .delete ? "goal.delete_detail" : "goal.reset_detail"
    }

    private func saveMetadata() async {
        guard let amount = decimalAmount(from: targetText) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let normalizedTargetDate = model.reportingCalendar.date(
                byAdding: .day,
                value: 1,
                to: model.reportingCalendar.startOfDay(for: targetDate)
            )?.addingTimeInterval(-1) ?? targetDate
            try await model.updateSavingsGoal(
                id: goalID,
                name: name,
                kind: kind,
                targetAmount: amount,
                targetDate: normalizedTargetDate,
                resetRule: resetRule
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleArchive() async {
        guard let goal else { return }
        do {
            try await model.setSavingsGoalArchived(id: goalID, isArchived: !goal.isArchived)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func resetGoal() async {
        pendingAction = nil
        do { try await model.resetSavingsGoal(id: goalID) }
        catch { errorMessage = error.localizedDescription }
    }

    private func deleteGoal() async {
        pendingAction = nil
        do {
            try await model.deleteSavingsGoal(id: goalID)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct GoalMovementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FocusState private var amountFocused: Bool
    let goalID: UUID
    let kind: SavingsGoalMovementKind

    @State private var amountText = ""
    @State private var occurredAt = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("goal.movement_amount", text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                DatePicker(
                    "goal.movement_date",
                    selection: $occurredAt,
                    in: ...Date(),
                    displayedComponents: .date
                )
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(kind.titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled((decimalAmount(from: amountText) ?? .zero) <= .zero || isSaving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("action.done") { amountFocused = false }
                }
            }
        }
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.addSavingsGoalMovement(
                goalID: goalID,
                kind: kind,
                amount: amount,
                occurredAt: occurredAt
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension SavingsGoalKind {
    var titleKey: LocalizedStringKey {
        switch self {
        case .savingsGoal: "goal.kind.savings"
        case .sinkingFund: "goal.kind.sinking"
        }
    }

    var systemImage: String {
        switch self {
        case .savingsGoal: "target"
        case .sinkingFund: "shippingbox.fill"
        }
    }
}

private extension SavingsGoalResetRule {
    var titleKey: LocalizedStringKey {
        switch self {
        case .never: "goal.reset.never"
        case .monthly: "goal.reset.monthly"
        case .yearly: "goal.reset.yearly"
        }
    }
}

private extension SavingsGoalMovementKind {
    var titleKey: LocalizedStringKey {
        switch self {
        case .contribution: "goal.contribute"
        case .withdrawal: "goal.withdraw"
        }
    }
}
