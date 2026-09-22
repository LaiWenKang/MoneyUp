import SwiftUI

extension QuickLogEntryView {
    var quickLogFormChrome: some View {
        quickLogFormContent
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSaving || isUndoing || isClearingDraft)
            .navigationTitle(title)
            .moneyUpNavigationSurface()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !dismissAfterSave {
                        Button("quick_log.clear_entry") { requestDraftClear() }
                            .disabled(!hasClearableDraft || isCheckingDuplicates)
                            .accessibilityIdentifier("quick-log-clear")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    MoneyUpAmountPrivacyButton()
                }
                if dismissAfterSave {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("action.cancel") { dismiss() }
                            .disabled(isSaving)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if !dismissAfterSave {
                        Menu {
                            Button {
                                navigate(to: .today)
                            } label: {
                                Label("tab.today", systemImage: "house.fill")
                            }
                            Button {
                                navigate(to: .history(nil))
                            } label: {
                                Label("tab.history", systemImage: "clock.arrow.circlepath")
                            }
                            Button {
                                navigate(to: .plan)
                            } label: {
                                Label("tab.plan", systemImage: "chart.pie.fill")
                            }
                            Button {
                                navigate(to: .assets)
                            } label: {
                                Label("tab.assets", systemImage: "wallet.bifold.fill")
                            }
                        } label: {
                            Label("quick_log.switch_tab", systemImage: "square.grid.2x2")
                        }
                    }

                    Button {
                        focusedField = .note
                    } label: {
                        Label("transaction.notes", systemImage: "note.text")
                    }
                    .accessibilityIdentifier("quick-log-keyboard-notes")

                    Button {
                        Task { await attemptSave() }
                    } label: {
                        Label("action.save", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave || isSaving || isUndoing || isPreparingEvidence)

                    Spacer()
                    Button {
                        dismissKeyboard()
                    } label: {
                        Label("action.done", systemImage: "keyboard.chevron.compact.down")
                    }
                    .fontWeight(.semibold)
                }
            }
    }

    /// The confirmation names the money that was just posted and offers Undo.
    func savedEntryBanner(entryID lastSavedEntryID: UUID) -> some View {
            HStack(spacing: 12) {
                Label {
                    HStack(spacing: 6) {
                        Text("quick_log.saved")
                        if let lastSavedAmountLabel {
                            Text(verbatim: "·").foregroundStyle(.secondary)
                            Text(lastSavedAmountLabel)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.moneyUpPositive)
                }
                .foregroundStyle(.primary)
                .lineLimit(1)
                Spacer(minLength: 8)
                Button("action.undo") {
                    Task { await undo(entryID: lastSavedEntryID) }
                }
                .fontWeight(.semibold)
                .disabled(isUndoing)
                Button {
                    updateSavedEntry(nil)
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("action.close")
                .disabled(isUndoing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .transition(
                MoneyUpMotion.confirmationTransition(
                    reduceMotion: accessibilityReduceMotion
                )
            )
    }

    /// A capture made while locked that could not open automatically because
    /// this form already holds typed input. One line, two actions, gone the
    /// moment it is opened or discarded. It never appears anywhere else.
    var pendingCaptureBanner: some View {
        PendingCaptureBanner(
            count: model.pendingLockedCaptureCount,
            isBusy: isSaving || isClearingDraft || model.isWorking,
            open: { Task { await openPendingCapture() } },
            discard: { Task { await discardPendingCaptures() } }
        )
    }

    @MainActor
    func openPendingCapture() async {
        do { try await model.reviewPendingLockedCapturesForBackup() }
        catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    @MainActor
    func discardPendingCaptures() async {
        do { try await model.discardPendingLockedCaptures() }
        catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}

/// A concrete view type keeps SwiftUI's value copying simple for a banner
/// that carries its own confirmation dialog.
struct PendingCaptureBanner: View {
    let count: Int
    let isBusy: Bool
    let open: () -> Void
    let discard: () -> Void
    @State private var isConfirmingDiscard = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(Color.moneyUpWarning)
            Text(String(format: AppLocalization.string("capture.waiting_format"), count))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Button("backup.review_pending_captures", action: open)
                .fontWeight(.semibold)
                .disabled(isBusy)
                .accessibilityIdentifier("log-open-pending-capture")
            Button {
                isConfirmingDiscard = true
            } label: {
                Image(systemName: "trash")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("capture.discard_pending")
            .accessibilityIdentifier("log-discard-pending-captures")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .confirmationDialog(
            "capture.discard_pending",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("capture.discard_pending", role: .destructive, action: discard)
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("capture.discard_pending_detail")
        }
    }
}
