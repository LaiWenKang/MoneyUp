import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import SwiftUI

struct IntelligenceScheduleSelection: Identifiable {
    let findingID: String
    let ruleID: String
    let offer: ScheduleOffer

    var id: String { findingID }
}

struct IntelligenceScheduleReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: IntelligenceScheduleSelection
    @State private var name: String
    @State private var amountText: String
    @State private var accountID: UUID
    @State private var categoryID: UUID
    @State private var nextOccurrence: Date
    @State private var frequency: RecurrenceFrequency
    @State private var didApplyReportingDate = false
    @State private var isSaving = false
    @State private var amountValidationMessage: String?
    @State private var errorMessage: String?

    init(selection: IntelligenceScheduleSelection) {
        self.selection = selection
        let offer = selection.offer
        _name = State(initialValue: offer.payeeKey)
        _amountText = State(initialValue: editableAmount(offer.amount.amount))
        _accountID = State(initialValue: offer.accountID)
        _categoryID = State(initialValue: offer.categoryID)
        _nextOccurrence = State(
            initialValue: intelligenceDate(
                offer.expectedNextDay,
                calendar: FinancialPeriodBoundary.gregorianCalendar(
                    timeZoneIdentifier: "GMT"
                )
            ) ?? Date()
        )
        _frequency = State(initialValue: offer.frequency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("schedule.name", text: $name)
                    TextField("transaction.amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .moneyUpFieldValidation(amountValidationMessage)
                    if let amountValidationMessage {
                        MoneyUpFieldError(message: amountValidationMessage)
                    }
                    Picker("transaction.account", selection: $accountID) {
                        ForEach(eligibleAccounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    Picker("transaction.category", selection: $categoryID) {
                        ForEach(eligibleCategories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    DatePicker(
                        "schedule.next",
                        selection: $nextOccurrence,
                        displayedComponents: [.date]
                    )
                    Picker("schedule.frequency", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases, id: \.self) { option in
                            Text(option.intelligenceTitleKey).tag(option)
                        }
                    }
                } header: {
                    Text("intelligence.schedule.prefill")
                } footer: {
                    Text("intelligence.schedule.confirmation_detail")
                }

                Section {
                    LabeledContent(
                        "intelligence.schedule.source_rule",
                        value: selection.ruleID
                    )
                }

            }
            .navigationTitle("intelligence.schedule.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("intelligence.schedule.add") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSave)
                }
            }
            .onAppear { applyReportingDateOnce() }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var eligibleAccounts: [LedgerAccount] {
        model.userAccounts.filter { $0.currency == selection.offer.amount.currency }
    }

    private var eligibleCategories: [LedgerAccount] {
        switch selection.offer.kind {
        case .expense: model.expenseCategories
        case .income: model.incomeCategories
        case .transfer, .adjustment, .investment: []
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && decimalAmount(from: amountText).map { $0 > .zero } == true
            && eligibleAccounts.contains { $0.id == accountID }
            && eligibleCategories.contains { $0.id == categoryID }
    }

    private func applyReportingDateOnce() {
        guard !didApplyReportingDate,
              let date = intelligenceDate(
                  selection.offer.expectedNextDay,
                  calendar: model.reportingCalendar
              ) else { return }
        didApplyReportingDate = true
        nextOccurrence = date
    }

    @MainActor
    private func save() async {
        amountValidationMessage = nil
        errorMessage = nil
        guard let amount = decimalAmount(from: amountText), amount > .zero else {
            amountValidationMessage = AppLocalization.string("error.invalid_amount")
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let schedule = try ScheduledTransaction(
                kind: selection.offer.kind,
                name: name,
                amount: Money(amount, currency: selection.offer.amount.currency),
                accountID: accountID,
                categoryAccountID: categoryID,
                nextOccurrence: nextOccurrence,
                frequency: frequency,
                recurrenceTimeZoneIdentifier: model.reportingCalendar.timeZone.identifier
            )
            try await model.addScheduledTransaction(schedule)
            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

extension RecurrenceFrequency {
    fileprivate var intelligenceTitleKey: LocalizedStringKey {
        switch self {
        case .weekly: "schedule.weekly"
        case .monthly: "schedule.monthly"
        case .yearly: "schedule.yearly"
        }
    }
}
