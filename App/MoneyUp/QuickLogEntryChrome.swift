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
}
