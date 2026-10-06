import SwiftUI
import UIKit

/// The Settings row that opens the reminders and shows what is on at a glance.
struct ReminderSettingsEntry: View {
    var body: some View {
        Section {
            NavigationLink {
                ReminderSettingsView()
            } label: {
                LabeledContent {
                    ReminderSummaryText()
                } label: {
                    Label("settings.reminders.setup", systemImage: "bell.badge")
                }
            }
            .accessibilityIdentifier("settings-reminders")
        } header: {
            MoneyUpSectionHeader("settings.reminders", explanation: "settings.reminders_detail")
        }
    }
}

struct ReminderSummaryText: View {
    var body: some View {
        // Read here so the count follows a change made on the reminders screen.
        let _ = ReminderCenter.shared.revision
        let count = ReminderPreferences.load().enabledCount
        Text(verbatim: count == 0
            ? AppLocalization.string("settings.reminders.summary_off")
            : String(format: AppLocalization.string("settings.reminders.summary_on_format"), count))
    }
}

/// Everything about reminders on one screen: what to be reminded of, when,
/// how it arrives, and a test so the result can be seen before relying on it.
/// Choices are device preferences; nothing here reads or stores the book.
struct ReminderSettingsView: View {
    @State private var preferences = ReminderPreferences.load()
    @Environment(\.scenePhase) private var scenePhase
    private let center = ReminderCenter.shared

    var body: some View {
        Form {
            ReminderPermissionSection()
            ReminderBillsSection(preferences: $preferences)
            if preferences.billsEnabled {
                ReminderLeadDaysSection(preferences: $preferences)
            }
            ReminderDailySection(preferences: $preferences)
            if preferences.dailyEnabled {
                ReminderWeekdaysSection(preferences: $preferences)
            }
            ReminderWeeklySection(preferences: $preferences)
            ReminderStyleSection(preferences: $preferences)
            ReminderTestSection(style: preferences.style)
        }
        .navigationTitle("settings.reminders")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: preferences) { old, new in
            new.save()
            center.preferencesDidChange()
            if new.turnsOnReminders(since: old) {
                Task { await center.requestAuthorizationIfNeeded() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from iOS Settings: the permission may have changed.
            if phase == .active { Task { await center.refreshAuthorization() } }
        }
        .task { await center.refreshAuthorization() }
        .onDisappear {
            let tidy = preferences.tidied()
            guard tidy != preferences else { return }
            tidy.save()
            center.preferencesDidChange()
        }
    }
}

/// Shown only while iOS has notifications off for MoneyUp.
struct ReminderPermissionSection: View {
    @Environment(\.openURL) private var openURL
    private let center = ReminderCenter.shared

    var body: some View {
        if center.authorization == .denied {
            Section {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("settings.reminders.denied", systemImage: "bell.slash")
                }
                .accessibilityIdentifier("settings-reminders-denied")
            }
        }
    }
}

struct ReminderBillsSection: View {
    @Binding var preferences: ReminderPreferences

    var body: some View {
        Section {
            Toggle("settings.reminders.bills", isOn: $preferences.billsEnabled)
                .accessibilityIdentifier("settings-reminders-bills")
            if preferences.billsEnabled {
                ReminderTimeRow(
                    title: "settings.reminders.time",
                    identifier: "settings-reminders-bills-time",
                    minute: $preferences.billMinute
                )
                Toggle("settings.reminders.income", isOn: $preferences.includesIncome)
                    .accessibilityIdentifier("settings-reminders-income")
            }
        } footer: {
            Text("settings.reminders.bills_footer")
        }
    }
}

struct ReminderLeadDaysSection: View {
    @Binding var preferences: ReminderPreferences

    var body: some View {
        Section {
            ForEach(ReminderPreferences.leadDayChoices, id: \.self) { day in
                ReminderChoiceRow(title: Self.title(for: day), isOn: preferences.billLeadDays.contains(day)) {
                    preferences.toggleLeadDay(day)
                }
                .accessibilityIdentifier("settings-reminders-lead-\(day)")
            }
        } header: {
            Text("settings.reminders.lead_header")
        } footer: {
            Text("settings.reminders.lead_footer")
        }
    }

    static func title(for day: Int) -> Text {
        switch day {
        case 0: Text("settings.reminders.lead_same_day")
        case 1: Text("settings.reminders.lead_1")
        case 2: Text("settings.reminders.lead_2")
        case 3: Text("settings.reminders.lead_3")
        default: Text("settings.reminders.lead_7")
        }
    }
}

struct ReminderDailySection: View {
    @Binding var preferences: ReminderPreferences

    var body: some View {
        Section {
            Toggle("settings.reminders.daily", isOn: $preferences.dailyEnabled)
                .accessibilityIdentifier("settings-reminders-daily")
            if preferences.dailyEnabled {
                ForEach(Array(preferences.dailyMinutes.indices), id: \.self) { index in
                    ReminderDailyTimeRow(preferences: $preferences, index: index)
                }
                if preferences.dailyMinutes.count < ReminderPreferences.maximumDailyTimes {
                    Button {
                        preferences.addDailyTime()
                    } label: {
                        // Icon and words are separate columns, so a second line stays under the words.
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .accessibilityHidden(true)
                            Text("settings.reminders.add_time")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("settings-reminders-add-time")
                }
                Toggle("settings.reminders.skip_logged", isOn: $preferences.dailySkipsWhenLogged)
                    .accessibilityIdentifier("settings-reminders-skip-logged")
            }
        } footer: {
            Text("settings.reminders.daily_footer")
        }
    }
}

/// One daily time. Each row can go except the last: turn the reminder off instead.
struct ReminderDailyTimeRow: View {
    @Binding var preferences: ReminderPreferences
    let index: Int

    var body: some View {
        // Identifiers sit on the leaf controls: one on this stack would replace
        // the ones its children carry.
        HStack {
            ReminderTimeRow(
                title: index == 0 ? "settings.reminders.time" : "settings.reminders.also_at",
                identifier: "settings-reminders-time-\(index)",
                minute: minute
            )
            if preferences.dailyMinutes.count > 1 {
                Button(role: .destructive) {
                    preferences.removeDailyTime(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("settings.reminders.remove_time")
                .accessibilityIdentifier("settings-reminders-remove-time-\(index)")
            }
        }
    }

    /// Rows can outlive the time they show for a frame after a removal.
    private var minute: Binding<Int> {
        Binding(
            get: {
                preferences.dailyMinutes.indices.contains(index)
                    ? preferences.dailyMinutes[index]
                    : ReminderPreferences.defaultDailyMinute
            },
            set: { value in
                if preferences.dailyMinutes.indices.contains(index) {
                    preferences.dailyMinutes[index] = value
                }
            }
        )
    }
}

struct ReminderWeekdaysSection: View {
    @Binding var preferences: ReminderPreferences
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            ForEach(ReminderWeekdays.ordered(), id: \.self) { weekday in
                ReminderChoiceRow(
                    title: Text(verbatim: ReminderWeekdays.name(weekday, locale: locale)),
                    isOn: preferences.dailyWeekdays.contains(weekday)
                ) {
                    preferences.toggleDailyWeekday(weekday)
                }
                .accessibilityIdentifier("settings-reminders-weekday-\(weekday)")
            }
        } header: {
            Text("settings.reminders.days_header")
        } footer: {
            Text("settings.reminders.days_footer")
        }
    }
}

struct ReminderWeeklySection: View {
    @Binding var preferences: ReminderPreferences
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            Toggle("settings.reminders.weekly", isOn: $preferences.weeklyEnabled)
                .accessibilityIdentifier("settings-reminders-weekly")
            if preferences.weeklyEnabled {
                Picker("settings.reminders.weekly_day", selection: $preferences.weeklyWeekday) {
                    ForEach(ReminderWeekdays.ordered(), id: \.self) { weekday in
                        Text(verbatim: ReminderWeekdays.name(weekday, locale: locale)).tag(weekday)
                    }
                }
                .accessibilityIdentifier("settings-reminders-weekly-day")
                ReminderTimeRow(
                    title: "settings.reminders.time",
                    identifier: "settings-reminders-weekly-time",
                    minute: $preferences.weeklyMinute
                )
            }
        } footer: {
            Text("settings.reminders.weekly_footer")
        }
    }
}

struct ReminderStyleSection: View {
    @Binding var preferences: ReminderPreferences

    var body: some View {
        Section {
            ReminderToggleRow(
                title: "settings.reminders.details",
                hint: "settings.reminders.details_hint",
                identifier: "settings-reminders-details",
                isOn: $preferences.showsDetails
            )
            Toggle("settings.reminders.sound", isOn: $preferences.playsSound)
                .accessibilityIdentifier("settings-reminders-sound")
            ReminderToggleRow(
                title: "settings.reminders.snooze",
                hint: "settings.reminders.snooze_hint",
                identifier: "settings-reminders-snooze",
                isOn: $preferences.allowsSnooze
            )
        } header: {
            Text("settings.reminders.style_header")
        }
    }
}

/// Sends one reminder in a few seconds, with the current sound and buttons.
struct ReminderTestSection: View {
    let style: ReminderStyle
    @State private var isSent = false
    private let center = ReminderCenter.shared

    var body: some View {
        Section {
            Button {
                Task { await sendTestReminder() }
            } label: {
                Label("settings.reminders.test", systemImage: "bell.and.waves.left.and.right")
            }
            .disabled(isSent || center.authorization == .denied)
            .accessibilityIdentifier("settings-reminders-test")
        } footer: {
            if isSent {
                Text("settings.reminders.test_sent")
                    .accessibilityIdentifier("settings-reminders-test-sent")
            } else {
                Text("settings.reminders.test_footer")
            }
        }
    }

    private func sendTestReminder() async {
        await center.requestAuthorizationIfNeeded()
        guard center.canNotify else { return }
        center.sendTest(style: style)
        isSent = true
        try? await Task.sleep(for: .seconds(6))
        isSent = false
    }
}

/// A time of day, kept as minutes after midnight.
struct ReminderTimeRow: View {
    let title: LocalizedStringKey
    let identifier: String
    @Binding var minute: Int

    var body: some View {
        DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
            .accessibilityIdentifier(identifier)
    }

    private var date: Binding<Date> {
        let calendar = Calendar.current
        return Binding(
            get: {
                calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
            },
            set: { value in
                let parts = calendar.dateComponents([.hour, .minute], from: value)
                minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

/// A switch with a line of explanation under its title.
struct ReminderToggleRow: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let identifier: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// One choice in a list where several can be on. The whole row is the target.
struct ReminderChoiceRow: View {
    let title: Text
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                title.foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isOn {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Weekday numbers in the order this iPhone's region shows a week, and their
/// names in the app language. 1 is Sunday, as in `Calendar`.
enum ReminderWeekdays {
    static func ordered(firstWeekday: Int = Calendar.autoupdatingCurrent.firstWeekday) -> [Int] {
        let first = (1...7).contains(firstWeekday) ? firstWeekday : 1
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    static func name(_ weekday: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let names = calendar.standaloneWeekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }
}
