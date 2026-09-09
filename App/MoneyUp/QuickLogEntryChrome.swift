import SwiftUI

extension QuickLogEntryView {
    var quickLogFormChrome: some View {
        quickLogFormContent
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSaving || isUndoing || isClearingDraft)
            .navigationTitle(title)
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

}
