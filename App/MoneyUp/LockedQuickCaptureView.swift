import SwiftUI

struct LockedQuickCaptureView: View {
    @EnvironmentObject private var model: AppModel
    let mode: QuickLogLaunchMode

    @State private var amountText = ""
    @State private var payee = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        guard let amount = decimalAmount(from: amountText) else { return false }
        return amount > .zero
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("capture.private", systemImage: "lock.shield.fill")
                        .foregroundStyle(.tint)
                    Text("capture.detail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("quick_log.amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                    if mode != .transfer {
                        TextField("transaction.payee", text: $payee)
                    }
                    TextField("quick_log.note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text(mode.kind.title)
                } footer: {
                    Text("capture.reconcile_later")
                }

                Button {
                    Task { await unlock() }
                } label: {
                    Label("capture.unlock_instead", systemImage: "faceid")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .disabled(isSaving)
            .navigationTitle("capture.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") {
                        model.consumeQuickLogRequest(mode)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.saveLockedCapture(
                mode: mode,
                amountText: amountText,
                payee: payee,
                note: note
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlock() async {
        isSaving = true
        defer { isSaving = false }
        await model.start()
    }
}
