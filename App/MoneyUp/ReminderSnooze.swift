import Foundation

/// The kind of reminder a pending or delivered request belongs to.
enum ReminderKind: Equatable, Sendable {
    case bill
    case daily
    case weekly
    case test

    init?(identifier: String) {
        let rest: Substring
        if identifier.hasPrefix(ReminderPlanner.identifierPrefix) {
            rest = identifier.dropFirst(ReminderPlanner.identifierPrefix.count)
        } else if identifier.hasPrefix(ReminderSnooze.requestPrefix) {
            rest = identifier.dropFirst(ReminderSnooze.requestPrefix.count)
        } else {
            return nil
        }
        switch rest.split(separator: ".").first {
        case "bill": self = .bill
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "test": self = .test
        default: return nil
        }
    }
}

/// The "remind me again" buttons on a reminder, and the rules for the copy
/// they leave behind. Pure: no clock and no notification center.
enum ReminderSnooze: String, CaseIterable, Sendable {
    case inOneHour = "moneyup.snooze.hour"
    case tomorrow = "moneyup.snooze.tomorrow"

    /// The notification category that carries the snooze buttons.
    static let categoryIdentifier = "moneyup.reminder.snoozable"
    /// A snoozed reminder is its own pending request under this prefix, so a
    /// planning pass that replaces the schedule never removes it by accident.
    static let requestPrefix = "moneyup.snoozed."

    var titleKey: String {
        switch self {
        case .inOneHour: "reminder.snooze_hour"
        case .tomorrow: "reminder.snooze_tomorrow"
        }
    }

    func fireDate(from now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .inOneHour: calendar.date(byAdding: .hour, value: 1, to: now)
        case .tomorrow: calendar.date(byAdding: .day, value: 1, to: now)
        }
    }

    /// One pending copy per reminder: snoozing the same reminder again
    /// replaces the first copy instead of adding another.
    static func requestIdentifier(snoozing identifier: String) -> String {
        for prefix in [ReminderPlanner.identifierPrefix, requestPrefix] where identifier.hasPrefix(prefix) {
            return requestPrefix + identifier.dropFirst(prefix.count)
        }
        return requestPrefix + identifier
    }

    struct Pending: Equatable, Sendable {
        let identifier: String
        let carriesDetails: Bool
    }

    /// Snoozed copies that no longer match the choices. What a copy says was
    /// fixed when it was made, so it must not outlive the choice that allowed
    /// it: reminders or snoozing turned off, that kind of reminder turned off,
    /// or names and amounts turned off.
    static func discarded(_ pending: [Pending], preferences: ReminderPreferences) -> [String] {
        pending.filter { item in
            guard preferences.allowsSnooze, let kind = ReminderKind(identifier: item.identifier) else { return true }
            let isEnabled = switch kind {
            case .bill: preferences.billsEnabled
            case .daily: preferences.dailyEnabled
            case .weekly: preferences.weeklyEnabled
            case .test: preferences.isAnyEnabled
            }
            return !isEnabled || (item.carriesDetails && !preferences.showsDetails)
        }.map(\.identifier)
    }
}

/// What to do with a person's reply to a delivered reminder.
enum ReminderResponse: Equatable, Sendable {
    case open(PlannedReminder.Route)
    case snooze(ReminderSnooze)
    case ignore

    static func isReminder(_ identifier: String) -> Bool {
        identifier.hasPrefix(ReminderPlanner.identifierPrefix) || identifier.hasPrefix(ReminderSnooze.requestPrefix)
    }

    static func decide(
        actionIdentifier: String,
        isDefaultAction: Bool,
        requestIdentifier: String,
        rawRoute: String?
    ) -> ReminderResponse {
        guard isReminder(requestIdentifier) else { return .ignore }
        if isDefaultAction {
            return rawRoute.flatMap(PlannedReminder.Route.init(rawValue:)).map(ReminderResponse.open) ?? .ignore
        }
        return ReminderSnooze(rawValue: actionIdentifier).map(ReminderResponse.snooze) ?? .ignore
    }

    /// In the app, a logging or weekly nudge is noise; a due payment is still news.
    static func showsInForeground(_ identifier: String) -> Bool {
        switch ReminderKind(identifier: identifier) {
        case .daily, .weekly: false
        case .bill, .test, nil: true
        }
    }
}
