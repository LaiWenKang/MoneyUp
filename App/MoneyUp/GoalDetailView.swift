import MoneyUpCore
import SwiftUI

struct GoalDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appReportingSnapshot) private var reportingSnapshot
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var isEditing = false
    @State private var movement: SavingsGoalMovementKind?
    let goalID: UUID

    private var goal: SavingsGoal? { model.savingsGoals.first { $0.id == goalID } }

    var body: some View {
        let _ = hidesAmounts
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let goal {
                        switch model.savingsGoalSummary(goal, asOf: reportingSnapshot?.instant ?? model.currentDateForUserAction()) {
                        case let .available(summary):
                            progressCard(goal, summary: summary)
                            if !goal.isArchived, goal.resetRule == .never {
                                GoalContributionSimulator(summary: summary, calendar: FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: goal.reportingTimeZoneIdentifier))
                            }
                        case let .unavailable(issue):
                            MoneyUpCard { DerivedValueUnavailableView(issue: issue, prominent: true) }
                        }
                    }
                }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background { MoneyUpBackdrop() }
            .navigationTitle(goal?.name ?? AppLocalization.string("plan.goals"))
            .moneyUpNavigationSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { MoneyUpAmountPrivacyButton() }
                ToolbarItem(placement: .primaryAction) { Button("action.edit") { isEditing = true } }
                MoneyUpKeyboardDoneToolbar()
            }
            .onChange(of: goal?.id) { _, id in if id == nil { dismiss() } }
            .sheet(isPresented: $isEditing) { GoalManagementSheet(goalID: goalID) }
            .sheet(item: $movement) { GoalMovementSheet(goalID: goalID, kind: $0) }
        }
    }

    private func progressCard(_ goal: SavingsGoal, summary: SavingsGoalSummary) -> some View {
        MoneyUpCard(style: .floating) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    MoneyUpProgressDial(fraction: NSDecimalNumber(decimal: summary.progress).doubleValue, systemImage: goal.kind.systemImage)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.isComplete ? "goal.complete" : "goal.remaining").font(.subheadline).foregroundStyle(.secondary)
                        Text(formattedMoney(summary.remaining)).moneyUpFinancialValue(.prominent)
                    }
                }
                LabeledContent("goal.balance", value: formattedMoney(summary.balance))
                LabeledContent("goal.target", value: formattedMoney(summary.target))
                LabeledContent("goal.reset_rule") { Text(goal.resetRule.titleKey) }
                LabeledContent("goal.target_date") {
                    Text(goal.targetDate.formattedForReporting(.dateTime.year().month().day(), calendar: FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: goal.reportingTimeZoneIdentifier)))
                }
                if !goal.isArchived {
                    ViewThatFits(in: .horizontal) {
                        HStack { movementButtons }
                        VStack(alignment: .leading) { movementButtons }
                    }
                }
            }
        }
    }

    private var movementButtons: some View {
        ForEach(SavingsGoalMovementKind.allCases, id: \.self) { kind in
            Button { movement = kind } label: { Label(kind.titleKey, systemImage: kind == .contribution ? "plus.circle" : "minus.circle") }
                .buttonStyle(.bordered)
        }
    }
}

struct GoalContributionSimulator: View {
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var contributionText = ""
    @State private var cadence: GoalContributionCadence = .monthly
    @FocusState private var amountFocused: Bool
    let summary: SavingsGoalSummary
    let calendar: Calendar

    init(summary: SavingsGoalSummary, calendar: Calendar, initialContributionText: String = "") {
        self.summary = summary
        self.calendar = calendar
        _contributionText = State(initialValue: initialContributionText)
    }

    private var projection: Result<GoalContributionProjection, Error>? {
        guard !contributionText.isEmpty else { return nil }
        return Result {
            guard let amount = decimalAmount(from: contributionText), amount > .zero,
                  summary.target.currency.supports(amount) else { throw GoalContributionProjectionError.invalidInput }
            return try GoalContributionProjection.make(
                balance: summary.balance, target: summary.target,
                contribution: Money(amount, currency: summary.target.currency),
                cadence: cadence, asOf: summary.asOf, calendar: calendar
            )
        }
    }

    private var validationMessage: String? {
        guard case let .failure(error) = projection else { return nil }
        if case GoalContributionProjectionError.beyondHorizon = error { return nil }
        return AppLocalization.string("goal.simulator.invalid")
    }

    var body: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("goal.simulator.title", systemImage: "slider.horizontal.3").font(.headline)
                Text("goal.simulator.detail").font(.caption).foregroundStyle(.secondary)
                Picker("goal.simulator.cadence", selection: $cadence) {
                    Text("goal.simulator.weekly").tag(GoalContributionCadence.weekly)
                    Text("goal.simulator.monthly").tag(GoalContributionCadence.monthly)
                }.pickerStyle(.menu)
                TextField("goal.movement_amount", text: $contributionText)
                    .moneyAmountKeyboard(currency: summary.target.currency)
                    .focused($amountFocused)
                    .textFieldStyle(.roundedBorder)
                    .moneyUpFieldValidation(validationMessage)
                    .moneyUpPrivateAmountInput(
                        masked: hidesAmounts && !amountFocused && !contributionText.isEmpty,
                        accessibilityLabel: Text("goal.movement_amount")
                    ) { amountFocused = true }
                projectionContent
                if !contributionText.isEmpty {
                    Button("simulator.reset") { contributionText = ""; amountFocused = false }
                }
            }
        }
    }

    @ViewBuilder
    private var projectionContent: some View {
        switch projection {
        case let .success(preview):
            MoneyUpFlowDiagram(
                source: MoneyUpFlowNode(title: formattedMoney(summary.balance), symbol: "circle.dotted"),
                destination: MoneyUpFlowNode(title: formattedMoney(preview.projectedBalance), symbol: "flag.checkered")
            )
            Label(String(format: AppLocalization.string("goal.simulator.deposits"), preview.periods), systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
            Text(preview.completionDate.formattedForReporting(.dateTime.year().month().day(), calendar: calendar))
                .font(.subheadline).foregroundStyle(.secondary)
            if preview.completionDate > summary.targetDate {
                Label("goal.simulator.after_target", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("simulator.no_changes_saved").font(.caption).foregroundStyle(.secondary)
        case .failure(GoalContributionProjectionError.beyondHorizon):
            Text("goal.simulator.horizon").font(.caption).foregroundStyle(.secondary)
        case .failure:
            if let validationMessage { MoneyUpFieldError(message: validationMessage) }
        case nil:
            HStack {
                MoneyUpIllustration("MoneyUpScenarioStudio", role: .inline)
                Text("goal.simulator.prompt").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
