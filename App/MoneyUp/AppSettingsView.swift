import SwiftUI

private enum AutoLockChoice: TimeInterval, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3_600

    var id: TimeInterval { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .immediately: "settings.lock.immediately"
        case .oneMinute: "settings.lock.one_minute"
        case .fiveMinutes: "settings.lock.five_minutes"
        case .fifteenMinutes: "settings.lock.fifteen_minutes"
        case .oneHour: "settings.lock.one_hour"
        }
    }
}

struct AppSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?

    private var selectedAutoLockDelay: TimeInterval {
        model.profile?.autoLockDelay ?? AutoLockChoice.oneMinute.rawValue
    }

    /// Older releases offered additional whole-minute delays. The decoder
    /// intentionally preserves those values, so Settings must show that exact
    /// security policy until the user explicitly chooses a current option.
    private var legacyAutoLockDelay: TimeInterval? {
        let seconds = selectedAutoLockDelay
        guard AutoLockChoice(rawValue: seconds) == nil,
              seconds.isFinite,
              seconds >= 0,
              seconds.truncatingRemainder(dividingBy: 60) == 0 else {
            return nil
        }
        return seconds
    }

    private func legacyAutoLockTitle(seconds: TimeInterval) -> String {
        let minutes = (seconds / 60).formatted(
            .number.precision(.fractionLength(0))
        )
        return String(
            format: String(localized: "settings.lock.legacy_minutes_format"),
            minutes
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    "settings.auto_lock",
                    selection: Binding(
                        get: { selectedAutoLockDelay },
                        set: { seconds in
                            Task { await update { try await model.updateAutoLockDelay(seconds) } }
                        }
                    )
                ) {
                    ForEach(AutoLockChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                    if let legacyAutoLockDelay {
                        Text(legacyAutoLockTitle(seconds: legacyAutoLockDelay))
                            .tag(legacyAutoLockDelay)
                    }
                }

                Toggle(
                    "settings.locked_capture",
                    isOn: Binding(
                        get: { model.profile?.allowLockedQuickCapture ?? true },
                        set: { enabled in
                            Task { await update { try await model.updateLockedQuickCapture(enabled) } }
                        }
                    )
                )

                Button {
                    model.lock()
                } label: {
                    Label("lock.lock_now", systemImage: "lock.fill")
                }
            } header: {
                Text("settings.security")
            } footer: {
                Text("settings.auto_lock_detail")
            }

            Section {
                Picker(
                    "settings.default_account",
                    selection: Binding(
                        get: { model.profile?.preferredAccountID },
                        set: { value in
                            Task {
                                await update {
                                    try await model.updatePreferredAccount(value)
                                }
                            }
                        }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(model.userAccounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }

                Picker(
                    "settings.default_expense_category",
                    selection: Binding(
                        get: { model.profile?.preferredExpenseCategoryID },
                        set: { value in
                            Task {
                                await update {
                                    try await model.updatePreferredExpenseCategory(value)
                                }
                            }
                        }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(model.expenseCategories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }

                Picker(
                    "settings.default_income_category",
                    selection: Binding(
                        get: { model.profile?.preferredIncomeCategoryID },
                        set: { value in
                            Task {
                                await update {
                                    try await model.updatePreferredIncomeCategory(value)
                                }
                            }
                        }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(model.incomeCategories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
            } header: {
                Text("settings.quick_log")
            } footer: {
                Text("settings.smart_default_detail")
            }

            Section {
                Toggle(
                    "settings.widget.budget_status",
                    isOn: Binding(
                        get: { model.profile?.showsBudgetStatusWidget ?? false },
                        set: { enabled in
                            Task {
                                await update {
                                    try await model.updateBudgetStatusWidget(enabled)
                                }
                            }
                        }
                    )
                )
                .accessibilityHint("settings.widget.budget_status_hint")

                LabeledContent(
                    "settings.reporting_time_zone",
                    value: model.profile?.reportingTimeZoneIdentifier ?? "—"
                )
            } header: {
                Text("settings.widgets_and_reports")
            } footer: {
                Text("settings.widget.budget_status_detail")
            }

            Section {
                if model.pendingLockedCaptureCount > 0 {
                    LabeledContent(
                        "settings.pending_captures",
                        value: "\(model.pendingLockedCaptureCount)"
                    )
                }
                if model.recoveryIssueCount > 0 {
                    LabeledContent(
                        "settings.quarantined_records",
                        value: "\(model.recoveryIssueCount)"
                    )
                }

                NavigationLink {
                    DataSafetyView()
                } label: {
                    Label("backup.data_safety", systemImage: "externaldrive.badge.shield.checkmark")
                }

                NavigationLink {
                    ImportTransactionsView()
                } label: {
                    Label("import.title", systemImage: "square.and.arrow.down.on.square")
                }

                NavigationLink {
                    ExchangeRatesView()
                } label: {
                    Label("fx.title", systemImage: "arrow.left.arrow.right.circle")
                }

                NavigationLink {
                    PrivacyAndBetaView()
                } label: {
                    Label("privacy.title", systemImage: "hand.raised.fill")
                }
            } header: {
                Text("assets.data")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("settings.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func update(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
