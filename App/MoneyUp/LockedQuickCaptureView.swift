import SwiftUI

struct LockedQuickCaptureView: View {
    private enum FocusedField: Hashable {
        case amount
        case payee
        case note
    }

    @EnvironmentObject private var model: AppModel
    let mode: QuickLogLaunchMode

    private let unlockMethod = UnlockMethod.current

    @State private var amountText = ""
    @State private var payee = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isShowingOptionalDetails = false
    @State private var didSave = false
    @FocusState private var focusedField: FocusedField?

    private var hasValidAmount: Bool {
        guard amountText.utf8.count <= LockedCapture.maximumAmountByteCount,
              let amount = decimalAmount(from: amountText) else { return false }
        return amount > .zero
    }

    private var detailsFitCapture: Bool {
        payee.utf8.count <= LockedCapture.maximumPayeeByteCount
            && note.utf8.count <= LockedCapture.maximumNoteByteCount
    }

    private var canSave: Bool {
        hasValidAmount && detailsFitCapture
    }

    private var hasUnsavedInput: Bool {
        !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !payee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pendingCaptureCountText: String {
        String(
            format: String(localized: "capture.pending_count"),
            model.pendingLockedCaptureCount
        )
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
                            Text(pendingCaptureCountText)
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
                        .tint(.moneyUpAction)

                        Button {
                            Task { await unlock() }
                        } label: {
                            Label(
                                "capture.review_now",
                                systemImage: unlockMethod.systemImage
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!unlockMethod.isAvailable)
                    }
                } else {
                    Section {
                        Label("capture.private", systemImage: "lock.shield.fill")
                            .foregroundStyle(.tint)
                        Text("capture.detail")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if model.pendingLockedCaptureCount > 0 {
                            Text(pendingCaptureCountText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        TextField("quick_log.amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .focused($focusedField, equals: .amount)
                        if !amountText.isEmpty && !canSave
                            && payee.utf8.count <= LockedCapture.maximumPayeeByteCount
                            && note.utf8.count <= LockedCapture.maximumNoteByteCount {
                            Label(
                                "error.invalid_amount",
                                systemImage: "exclamationmark.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
                        }

                        DisclosureGroup(
                            "capture.add_details",
                            isExpanded: $isShowingOptionalDetails
                        ) {
                            if mode != .transfer {
                                TextField("transaction.payee", text: $payee)
                                    .focused($focusedField, equals: .payee)
                                if payee.utf8.count
                                    > LockedCapture.maximumPayeeByteCount {
                                    Label(
                                        "capture.input_too_long",
                                        systemImage: "exclamationmark.circle.fill"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                }
                            }
                            TextField("quick_log.note", text: $note, axis: .vertical)
                                .lineLimit(2...4)
                                .focused($focusedField, equals: .note)
                            if note.utf8.count > LockedCapture.maximumNoteByteCount {
                                Label(
                                    "capture.input_too_long",
                                    systemImage: "exclamationmark.circle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                    } header: {
                        Text(mode.kind.title)
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("capture.currency_unassigned")
                            Text("capture.reconcile_later")
                        }
                    }

                    Section {
                        Button {
                            Task { await save() }
                        } label: {
                            Label("capture.save", systemImage: "tray.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.moneyUpAction)
                        .disabled(!canSave || isSaving)

                        Button {
                            Task { await unlock() }
                        } label: {
                            Label(
                                "capture.unlock_instead",
                                systemImage: unlockMethod.systemImage
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!unlockMethod.isAvailable)
                    }

                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .scrollDismissesKeyboard(.interactively)
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
                        Button("capture.save") { Task { await save() } }
                            .disabled(!canSave || isSaving)
                        Spacer()
                        Button("action.done") { focusedField = nil }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .task {
            guard !didSave else { return }
            await Task.yield()
            focusedField = .amount
        }
        .sensoryFeedback(.success, trigger: didSave)
        .alert("error.could_not_save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("action.okay", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        guard canSave, !isSaving else { return }
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
            focusedField = nil
            didSave = true
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func unlock() async {
        guard !isSaving, unlockMethod.isAvailable else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // A valid form is first appended to the existing device-only encrypted
        // inbox. `didSave` is the view-level idempotency boundary: if
        // authentication is cancelled and the user retries, the same input is
        // not appended again. Promotion into authenticated Log remains the
        // model's existing exactly-once path and still requires normal review.
        if hasUnsavedInput, !didSave {
            guard hasValidAmount else {
                errorMessage = String(localized: "error.invalid_amount")
                focusedField = .amount
                return
            }
            guard detailsFitCapture else {
                errorMessage = String(localized: "capture.input_too_long")
                isShowingOptionalDetails = true
                focusedField = payee.utf8.count > LockedCapture.maximumPayeeByteCount
                    ? .payee : .note
                return
            }
        }
        if canSave, !didSave {
            do {
                try await model.saveLockedCapture(
                    mode: mode,
                    amountText: amountText,
                    payee: payee,
                    note: note
                )
                focusedField = nil
                didSave = true
            } catch {
                errorMessage = safeUserMessage(for: error, context: .save)
                return
            }
        }
        await model.start()
    }
}
