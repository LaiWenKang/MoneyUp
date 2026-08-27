import SwiftUI

struct LockedQuickCaptureView: View {
    @EnvironmentObject private var model: AppModel
    let mode: QuickLogLaunchMode

    @State private var amountText = ""
    @State private var payee = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isShowingOptionalDetails = false
    @State private var didSave = false
    @FocusState private var isAmountFocused: Bool

    private var canSave: Bool {
        guard let amount = decimalAmount(from: amountText) else { return false }
        return amount > .zero
    }

    var body: some View {
        NavigationStack {
            Form {
                if didSave {
                    Section {
                        VStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text("capture.saved_title")
                                .font(.title2.bold())
                            Text("capture.saved_detail")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Text(
                                String(
                                    format: String(localized: "capture.pending_count"),
                                    model.pendingLockedCaptureCount
                                )
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    Section {
                        Button {
                            model.consumeQuickLogRequest(mode)
                        } label: {
                            Label("action.done", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task { await unlock() }
                        } label: {
                            Label("capture.review_now", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else {
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
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .focused($isAmountFocused)

                        DisclosureGroup(
                            "capture.add_details",
                            isExpanded: $isShowingOptionalDetails
                        ) {
                            if mode != .transfer {
                                TextField("transaction.payee", text: $payee)
                            }
                            TextField("quick_log.note", text: $note, axis: .vertical)
                                .lineLimit(2...4)
                        }
                    } header: {
                        Text(mode.kind.title)
                    } footer: {
                        Text("capture.reconcile_later")
                    }

                    Section {
                        Button {
                            Task { await save() }
                        } label: {
                            Label("capture.save", systemImage: "tray.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave || isSaving)

                        Button {
                            Task { await unlock() }
                        } label: {
                            Label("capture.unlock_instead", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
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
                if !didSave {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("capture.save") { Task { await save() } }
                            .disabled(!canSave || isSaving)
                    }
                }
            }
        }
        .task {
            guard !didSave else { return }
            await Task.yield()
            isAmountFocused = true
        }
        .sensoryFeedback(.success, trigger: didSave)
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
            isAmountFocused = false
            didSave = true
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func unlock() async {
        isSaving = true
        defer { isSaving = false }
        await model.start()
    }
}
