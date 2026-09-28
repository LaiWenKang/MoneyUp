import SwiftUI
import UIKit
import UserNotifications

/// Local reminders: a due scheduled payment or income, and an optional daily
/// nudge to log. iOS asks for permission only when one is first turned on.
struct ReminderSettingsSection: View {
    @State private var preferences = ReminderPreferences.load()
    @Environment(\.openURL) private var openURL
    private let center = ReminderCenter.shared

    var body: some View {
        Section {
            Toggle("settings.reminders.bills", isOn: enabled(\.billsEnabled))
                .accessibilityIdentifier("settings-reminders-bills")
            if preferences.billsEnabled {
                DatePicker(
                    "settings.reminders.bills_time",
                    selection: time(\.billMinute),
                    displayedComponents: .hourAndMinute
                )
            }
            Toggle(isOn: enabled(\.dailyEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.reminders.daily")
                    Text("settings.reminders.daily_hint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-reminders-daily")
            if preferences.dailyEnabled {
                DatePicker(
                    "settings.reminders.daily_time",
                    selection: time(\.dailyMinute),
                    displayedComponents: .hourAndMinute
                )
            }
            if preferences.isAnyEnabled {
                Toggle(isOn: setting(\.showsDetails)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.reminders.details")
                        Text("settings.reminders.details_hint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if center.authorization == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("settings.reminders.denied", systemImage: "bell.slash")
                    }
                }
            }
        } header: {
            MoneyUpSectionHeader("settings.reminders", explanation: "settings.reminders_detail")
        }
        .task { await center.refreshAuthorization() }
    }

    /// A reminder switch; turning one on asks iOS for permission once.
    private func enabled(_ keyPath: WritableKeyPath<ReminderPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { isOn in
                update { $0[keyPath: keyPath] = isOn }
                guard isOn else { return }
                Task { await center.requestAuthorizationIfNeeded() }
            }
        )
    }

    private func setting(_ keyPath: WritableKeyPath<ReminderPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    /// Minutes after midnight shown as a time of day.
    private func time(_ keyPath: WritableKeyPath<ReminderPreferences, Int>) -> Binding<Date> {
        let calendar = Calendar.current
        return Binding(
            get: {
                let minute = preferences[keyPath: keyPath]
                return calendar.date(
                    bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                update { $0[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
            }
        )
    }

    private func update(_ change: (inout ReminderPreferences) -> Void) {
        change(&preferences)
        preferences.save()
        center.preferencesDidChange()
    }
}
