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

    static func closest(to seconds: TimeInterval) -> AutoLockChoice {
        allCases.min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }
            ?? .oneMinute
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker(
                    "settings.auto_lock",
                    selection: Binding(
                        get: {
                            AutoLockChoice.closest(
                                to: model.profile?.autoLockDelay ?? 60
                            )
                        },
                        set: { choice in
                            Task { await update { try await model.updateAutoLockDelay(choice.rawValue) } }
                        }
                    )
                ) {
                    ForEach(AutoLockChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
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
                    selection: optionalSelection(
                        get: { model.profile?.preferredAccountID },
                        update: { try await model.updatePreferredAccount($0) }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(model.userAccounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }

                Picker(
                    "settings.default_expense_category",
                    selection: optionalSelection(
                        get: { model.profile?.preferredExpenseCategoryID },
                        update: { try await model.updatePreferredExpenseCategory($0) }
                    )
                ) {
                    Text("settings.smart_default").tag(Optional<UUID>.none)
                    ForEach(model.expenseCategories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }

                Picker(
                    "settings.default_income_category",
                    selection: optionalSelection(
                        get: { model.profile?.preferredIncomeCategoryID },
                        update: { try await model.updatePreferredIncomeCategory($0) }
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
                if model.pendingLockedCaptureCount > 0 {
                    LabeledContent(
                        "settings.pending_captures",
                        value: "\(model.pendingLockedCaptureCount)"
                    )
                }
                if !model.recoveryIssues.isEmpty {
                    LabeledContent(
                        "settings.quarantined_records",
                        value: "\(model.recoveryIssues.count)"
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
        .navigationTitle("settings.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionalSelection(
        get: @escaping () -> UUID?,
        update operation: @escaping (UUID?) async throws -> Void
    ) -> Binding<UUID?> {
        Binding(
            get: get,
            set: { value in
                Task { await update { try await operation(value) } }
            }
        )
    }

    private func update(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
