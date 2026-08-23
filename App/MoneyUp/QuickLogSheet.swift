import Foundation
import SwiftUI

struct QuickLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isAmountFocused: Bool

    @State private var amountText = ""
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var isShowingFoundationNotice = false

    private var hasValidAmount: Bool {
        guard let amount = Decimal(string: amountText, locale: .current) else {
            return false
        }
        return amount > .zero
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("quick_log.amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                        .focused($isAmountFocused)

                    DatePicker(
                        "quick_log.date",
                        selection: $occurredAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    TextField("quick_log.note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("quick_log.foundation_note")
                }
            }
            .navigationTitle("quick_log.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("action.continue") {
                        isShowingFoundationNotice = true
                    }
                    .disabled(!hasValidAmount)
                }
            }
            .alert(
                "foundation.notice.title",
                isPresented: $isShowingFoundationNotice
            ) {
                Button("action.okay", role: .cancel) {}
            } message: {
                Text("foundation.notice.message")
            }
            .onAppear {
                isAmountFocused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}
