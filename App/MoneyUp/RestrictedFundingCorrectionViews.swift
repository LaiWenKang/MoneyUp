import MoneyUpCore
import SwiftUI

enum RestrictedFundingCorrectionEditorPolicy {
    static func initialNote(
        for record: RestrictedAllowanceFundingRecord
    ) -> String {
        record.note ?? ""
    }
}

struct RestrictedFundingCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let record: RestrictedAllowanceFundingRecord
    let onCorrected: () -> Void
    @State private var amountText: String
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        record: RestrictedAllowanceFundingRecord,
        onCorrected: @escaping () -> Void
    ) {
        self.record = record
        self.onCorrected = onCorrected
        _amountText = State(initialValue: editableAmount(record.amount.amount))
        _note = State(initialValue:
            RestrictedFundingCorrectionEditorPolicy.initialNote(for: record)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        "account.restricted_funding_original",
                        value: formattedMoney(record.amount)
                    )
                    LabeledContent("transaction.date") {
                        Text(record.occurredAt.formattedForReporting(
                            .dateTime.year().month().day().hour().minute(),
                            calendar: model.reportingCalendar
                        ))
                    }
                    TextField(
                        "account.restricted_funding_corrected",
                        text: $amountText
                    )
                    .moneyAmountKeyboard(currency: record.amount.currency)
                    TextField(
                        "transaction.description_or_notes",
                        text: $note,
                        axis: .vertical
                    )
                } footer: {
                    Text("account.restricted_funding_correction_detail")
                }
            }
            .navigationTitle("account.restricted_funding_correct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private var canSave: Bool {
        decimalAmount(from: amountText).map {
            $0 >= .zero && $0 < record.amount.amount
        } == true
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText), canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.correctRestrictedAllowanceFunding(
                expected: record,
                correctedAmount: amount,
                note: note
            )
            onCorrected()
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
