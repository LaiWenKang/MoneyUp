import MoneyUpCore
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
    @AppStorage(
        AppLanguagePreference.storageKey,
        store: AppLanguagePreference.defaults
    )
    private var appLanguageRawValue = AppLanguagePreference.system.rawValue
    @AppStorage(MoneyAmountPrivacy.storageKey)
    private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var errorMessage: String?
    @State private var isManagingCategories = false

    private var selectedAppLanguageRawValue: String {
        AppLanguagePreference(rawValue: appLanguageRawValue)?.rawValue
            ?? AppLanguagePreference.system.rawValue
    }

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
            format: AppLocalization.string("settings.lock.legacy_minutes_format"),
            minutes
        )
    }

    var body: some View {
        @Bindable var bindableModel = model
        Form {
            Section {
                NavigationLink {
                    DisplaySettingsView()
                } label: {
                    Label("display.title", systemImage: "slider.horizontal.3")
                }
            }
            Section {
                Picker(
                    selection: Binding(
                        get: { selectedAppLanguageRawValue },
                        set: { appLanguageRawValue = $0 }
                    )
                ) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        Text(language.titleKey).tag(language.rawValue)
                    }
                } label: {
                    Label("settings.language", systemImage: "globe")
                }

                Button {
                    isManagingCategories = true
                } label: {
                    Label(
                        "lifecycle.manage_categories",
                        systemImage: "square.grid.2x2"
                    )
                }
            } header: {
                MoneyUpSectionHeader("settings.customization", explanation: "settings.customization_detail")
            }

            CurrencySettingsSection()

            Section {
                Toggle(
                    isOn: Binding(
                        get: {
                            bindableModel.profile?.intelligenceEnabled ?? true
                        },
                        set: { enabled in
                            Task {
                                await update {
                                    try await bindableModel
                                        .updateIntelligenceEnabled(enabled)
                                }
                            }
                        }
                    )
                ) {
                    Label("settings.intelligence", systemImage: "sparkles")
                }
            } header: {
                MoneyUpSectionHeader("settings.intelligence_section", explanation: "settings.intelligence_detail")
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: {
                            bindableModel.profile?
                                .foundationModelAssistanceEnabled ?? true
                        },
                        set: { enabled in
                            Task {
                                await update {
                                    try await bindableModel
                                        .updateFoundationModelAssistance(enabled)
                                }
                            }
                        }
                    )
                ) {
                    Label("settings.on_device_assistance", systemImage: "cpu")
                }
            } header: {
                MoneyUpSectionHeader("settings.on_device_assistance_section", explanation: "settings.on_device_assistance_detail")
            }

            Section {
                Toggle(isOn: $hidesAmounts) {
                    Label("settings.hide_amounts", systemImage: "eye.slash")
                }
                .accessibilityHint("settings.hide_amounts_detail")

                Picker(
                    selection: Binding(
                        get: { selectedAutoLockDelay },
                        set: { seconds in
                            Task {
                                await update {
                                    try await bindableModel.updateAutoLockDelay(seconds)
                                }
                            }
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
                } label: {
                    Label("settings.auto_lock", systemImage: "timer")
                }

                Toggle(
                    isOn: Binding(
                        get: {
                            bindableModel.profile?.allowLockedQuickCapture ?? true
                        },
                        set: { enabled in
                            Task {
                                await update {
                                    try await bindableModel.updateLockedQuickCapture(enabled)
                                }
                            }
                        }
                    )
                ) {
                    Label("settings.locked_capture", systemImage: "bolt.badge.clock")
                }

                Button {
                    bindableModel.lock()
                } label: {
                    Label("lock.lock_now", systemImage: "lock.fill")
                }

                Label(
                    "settings.security.key_cliff_warning",
                    systemImage: "externaldrive.badge.checkmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                MoneyUpSectionHeader("settings.security", explanation: "settings.auto_lock_detail")
            }

            Section("catalog.settings_section") {
                NavigationLink { EntryCatalogView(scope: .accounts) }
                label: { Label("catalog.accounts_title", systemImage: "wallet.bifold") }
                NavigationLink { EntryCatalogView(scope: .expenses) }
                label: { Label("catalog.expenses_title", systemImage: "tag") }
            }

            Section {
                Picker(
                    "settings.default_account",
                    selection: Binding(
                        get: { bindableModel.profile?.preferredAccountID },
                        set: { value in
                            Task {
                                await update {
                                    try await bindableModel.updatePreferredAccount(value)
                                }
                            }
                        }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(LedgerEntryChoices.visible(bindableModel.userAccounts,
                        preserving: Set([bindableModel.profile?.preferredAccountID].compactMap { $0 })).filter {
                        $0.accountType != .restrictedAllowance
                    }) { account in
                        Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                    }
                }

                Picker(
                    "settings.default_expense_category",
                    selection: Binding(
                        get: {
                            bindableModel.profile?.preferredExpenseCategoryID
                        },
                        set: { value in
                            Task {
                                await update {
                                    try await bindableModel
                                        .updatePreferredExpenseCategory(value)
                                }
                            }
                        }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(LedgerEntryChoices.visible(bindableModel.expenseCategories,
                        preserving: Set([bindableModel.profile?.preferredExpenseCategoryID].compactMap { $0 }))) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }

                Picker(
                    "settings.default_income_category",
                    selection: Binding(
                        get: {
                            bindableModel.profile?.preferredIncomeCategoryID
                        },
                        set: { value in
                            Task {
                                await update {
                                    try await bindableModel
                                        .updatePreferredIncomeCategory(value)
                                }
                            }
                        }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(LedgerEntryChoices.visible(bindableModel.incomeCategories,
                        preserving: Set([bindableModel.profile?.preferredIncomeCategoryID].compactMap { $0 }))) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
            } header: {
                MoneyUpSectionHeader("settings.quick_log", explanation: "settings.smart_default_detail")
            }

            Section {
                Toggle(
                    "settings.widget.budget_status",
                    isOn: Binding(
                        get: {
                            bindableModel.profile?.showsBudgetStatusWidget ?? false
                        },
                        set: { enabled in
                            Task {
                                await update {
                                    try await bindableModel
                                        .updateBudgetStatusWidget(enabled)
                                }
                            }
                        }
                    )
                )
                .accessibilityHint("settings.widget.budget_status_hint")

                LabeledContent(
                    "settings.reporting_time_zone",
                    value: bindableModel.profile?.reportingTimeZoneIdentifier ?? "—"
                )
                if bindableModel.profile?.reportingTimeZoneIdentifier
                    != TimeZone.current.identifier {
                    Button {
                        Task {
                            await update {
                                try await bindableModel.updateReportingTimeZone(
                                    TimeZone.current.identifier
                                )
                            }
                        }
                    } label: {
                        Label("settings.use_device_time_zone", systemImage: "location.fill")
                    }
                }
            } header: {
                MoneyUpSectionHeader("settings.widgets_and_reports", explanation: "settings.widget.budget_status_detail")
            }

            Section {
                if bindableModel.pendingLockedCaptureCount > 0 {
                    LabeledContent(
                        "settings.pending_captures",
                        value: "\(bindableModel.pendingLockedCaptureCount)"
                    )
                }
                if bindableModel.recoveryIssueCount > 0 {
                    LabeledContent(
                        "settings.quarantined_records",
                        value: "\(bindableModel.recoveryIssueCount)"
                    )
                }

                NavigationLink {
                    DataSafetyView()
                } label: {
                    Label("backup.data_safety", systemImage: "externaldrive.badge.checkmark")
                }

                NavigationLink {
                    ImportTransactionsView()
                } label: {
                    Label("import.title", systemImage: "square.and.arrow.down.on.square")
                }

                NavigationLink {
                    PrivacyAndBetaView()
                } label: {
                    Label("privacy.title", systemImage: "hand.raised.fill")
                }
            } header: {
                Text("assets.data")
            }

            Section {
                NavigationLink {
                    DeveloperSupportView()
                } label: {
                    Label("support.title", systemImage: "cup.and.saucer.fill")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { MoneyUpBackdrop() }
        .moneyUpNavigationSurface()
        .navigationTitle("settings.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isManagingCategories) {
            CategoryManagementList()
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
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
