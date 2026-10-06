import Foundation
import MoneyUpCore

/// What a planned notification says, resolved into text only when it is
/// scheduled, so planning stays pure and testable.
enum ReminderMessage: Equatable, Sendable {
    /// A scheduled payment or income is due in `leadDays` days (0 is the day
    /// itself); no name or amount.
    case due(JournalEntryKind, leadDays: Int)
    /// The same, with the schedule's name and amount (opted in).
    case dueDetail(JournalEntryKind, leadDays: Int, name: String, amount: Money)
    case dailyLog
    case weeklyReview
    /// Sent on request from the reminder settings so the wording can be seen.
    case test

    var carriesDetails: Bool {
        if case .dueDetail = self { return true }
        return false
    }

    /// Where it ranks in a scheduled summary: what is due comes first.
    var relevance: Double {
        switch self {
        case .due, .dueDetail: 0.8
        case .weeklyReview, .test: 0.5
        case .dailyLog: 0.2
        }
    }
}

/// How a reminder sounds and behaves. Part of the plan, so changing it
/// reschedules what is already pending.
struct ReminderStyle: Equatable, Sendable {
    var playsSound = true
    var allowsSnooze = true
}

struct PlannedReminder: Equatable, Sendable {
    enum Route: String, Sendable {
        /// Opens Today, where the due item waits for review.
        case today
        /// Opens Log, exactly like a widget tap.
        case log
    }

    let identifier: String
    let fireDate: Date
    let message: ReminderMessage
    let route: Route
    var style = ReminderStyle()
}

/// Turns the book's schedules and the reminder choices into the exact set of
/// local notifications that should be pending. Pure: no clock, no I/O.
enum ReminderPlanner {
    static let identifierPrefix = "moneyup.reminder."
    /// How far ahead due dates are scheduled; opening the app extends it.
    static let billHorizonDays = 35
    static let maximumBillReminders = 48
    static let dailyReminderDays = 7
    static let weeklyReminderWeeks = 4
    /// iOS keeps at most 64 pending notifications per app. The plan stops
    /// short of that so a snoozed or test reminder always has room.
    static let maximumPendingReminders = 60

    static func plan(
        preferences: ReminderPreferences,
        schedules: [ScheduledTransaction],
        loggedToday: Bool,
        now: Date,
        calendar: Calendar
    ) -> [PlannedReminder] {
        var plan: [PlannedReminder] = []
        if preferences.billsEnabled {
            plan += billReminders(preferences: preferences, schedules: schedules, now: now, calendar: calendar)
        }
        if preferences.dailyEnabled {
            plan += dailyReminders(preferences: preferences, loggedToday: loggedToday, now: now, calendar: calendar)
        }
        if preferences.weeklyEnabled {
            plan += weeklyReminders(preferences: preferences, now: now, calendar: calendar)
        }
        return Array(plan.sorted(by: soonestFirst).prefix(maximumPendingReminders))
    }

    private static func soonestFirst(_ lhs: PlannedReminder, _ rhs: PlannedReminder) -> Bool {
        lhs.fireDate != rhs.fireDate ? lhs.fireDate < rhs.fireDate : lhs.identifier < rhs.identifier
    }

    private static func billReminders(
        preferences: ReminderPreferences,
        schedules: [ScheduledTransaction],
        now: Date,
        calendar: Calendar
    ) -> [PlannedReminder] {
        let leads = preferences.billLeadDays.sorted()
        guard let horizon = calendar.date(byAdding: .day, value: billHorizonDays, to: now),
              let searchEnd = calendar.date(byAdding: .day, value: leads.last ?? 0, to: horizon) else { return [] }
        var reminders: [PlannedReminder] = []
        for schedule in schedules where schedule.isActive && (preferences.includesIncome || schedule.kind != .income) {
            for occurrence in schedule.occurrences(through: searchEnd, calendar: calendar, maximumCount: 40) {
                for lead in leads {
                    guard let day = calendar.date(byAdding: .day, value: -lead, to: occurrence),
                          let fireDate = time(preferences.billMinute, onDayOf: day, calendar: calendar),
                          fireDate > now, fireDate <= horizon else { continue }
                    let message: ReminderMessage = preferences.showsDetails
                        ? .dueDetail(schedule.kind, leadDays: lead, name: schedule.name, amount: schedule.amount)
                        : .due(schedule.kind, leadDays: lead)
                    reminders.append(PlannedReminder(
                        identifier: identifierPrefix
                            + "bill.\(schedule.id.uuidString).\(dayKey(occurrence, calendar: calendar)).\(lead)",
                        fireDate: fireDate,
                        message: message,
                        route: .today,
                        style: preferences.style
                    ))
                }
            }
        }
        return Array(reminders.sorted(by: soonestFirst).prefix(maximumBillReminders))
    }

    private static func dailyReminders(
        preferences: ReminderPreferences,
        loggedToday: Bool,
        now: Date,
        calendar: Calendar
    ) -> [PlannedReminder] {
        (0..<dailyReminderDays).flatMap { offset -> [PlannedReminder] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  preferences.dailyWeekdays.contains(calendar.component(.weekday, from: day)),
                  !(offset == 0 && loggedToday && preferences.dailySkipsWhenLogged) else { return [] }
            return Set(preferences.dailyMinutes).sorted().compactMap { minute in
                guard let fireDate = time(minute, onDayOf: day, calendar: calendar), fireDate > now else { return nil }
                return PlannedReminder(
                    identifier: identifierPrefix
                        + "daily.\(dayKey(day, calendar: calendar)).\(String(format: "%04d", minute))",
                    fireDate: fireDate,
                    message: .dailyLog,
                    route: .log,
                    style: preferences.style
                )
            }
        }
    }

    private static func weeklyReminders(
        preferences: ReminderPreferences,
        now: Date,
        calendar: Calendar
    ) -> [PlannedReminder] {
        (0..<(weeklyReminderWeeks * 7)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  calendar.component(.weekday, from: day) == preferences.weeklyWeekday,
                  let fireDate = time(preferences.weeklyMinute, onDayOf: day, calendar: calendar),
                  fireDate > now else { return nil }
            return PlannedReminder(
                identifier: identifierPrefix + "weekly.\(dayKey(day, calendar: calendar))",
                fireDate: fireDate,
                message: .weeklyReview,
                route: .today,
                style: preferences.style
            )
        }
    }

    /// `minute` after the start of the calendar day containing `date`.
    static func time(_ minute: Int, onDayOf date: Date, calendar: Calendar) -> Date? {
        guard (0..<(24 * 60)).contains(minute) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = minute / 60
        components.minute = minute % 60
        return calendar.date(from: components)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
