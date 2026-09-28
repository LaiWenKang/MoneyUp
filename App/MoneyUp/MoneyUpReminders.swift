import Foundation
import MoneyUpCore
import Observation
import UIKit
import UserNotifications

/// Reminder choices for this iPhone. They are device preferences, not book
/// content: no amount, name or identifier from the book is ever stored here.
struct ReminderPreferences: Codable, Equatable, Sendable {
    static let storageKey = "moneyup.reminders"

    var billsEnabled = false
    /// Minutes after midnight, in the book's reporting time zone.
    var billMinute = 9 * 60
    var dailyEnabled = false
    var dailyMinute = 20 * 60
    /// Names and amounts appear in notifications only when this is on.
    var showsDetails = false

    var isAnyEnabled: Bool { billsEnabled || dailyEnabled }

    static func load(from defaults: UserDefaults = .standard) -> ReminderPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// What a planned notification says, resolved into text only when it is
/// scheduled, so planning stays pure and testable.
enum ReminderMessage: Equatable, Sendable {
    /// A scheduled payment or income is due; no name or amount.
    case due(JournalEntryKind)
    /// The same, with the schedule's name and amount (opted in).
    case dueDetail(JournalEntryKind, name: String, amount: Money)
    case dailyLog
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
}

/// Turns the book's schedules and the reminder choices into the exact set of
/// local notifications that should be pending. Pure: no clock, no I/O.
enum ReminderPlanner {
    static let identifierPrefix = "moneyup.reminder."
    /// How far ahead due dates are scheduled; opening the app extends it.
    static let billHorizonDays = 35
    /// iOS keeps at most 64 pending notifications per app.
    static let maximumBillReminders = 48
    static let dailyReminderDays = 7

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
        return plan
    }

    private static func billReminders(
        preferences: ReminderPreferences,
        schedules: [ScheduledTransaction],
        now: Date,
        calendar: Calendar
    ) -> [PlannedReminder] {
        guard let horizon = calendar.date(byAdding: .day, value: billHorizonDays, to: now) else { return [] }
        var reminders: [PlannedReminder] = []
        for schedule in schedules where schedule.isActive {
            for occurrence in schedule.occurrences(through: horizon, calendar: calendar, maximumCount: 40) {
                guard let fireDate = time(preferences.billMinute, onDayOf: occurrence, calendar: calendar),
                      fireDate > now else { continue }
                let message: ReminderMessage = preferences.showsDetails
                    ? .dueDetail(schedule.kind, name: schedule.name, amount: schedule.amount)
                    : .due(schedule.kind)
                reminders.append(PlannedReminder(
                    identifier: identifierPrefix + "bill.\(schedule.id.uuidString).\(dayKey(occurrence, calendar: calendar))",
                    fireDate: fireDate,
                    message: message,
                    route: .today
                ))
            }
        }
        return Array(reminders.sorted {
            $0.fireDate != $1.fireDate ? $0.fireDate < $1.fireDate : $0.identifier < $1.identifier
        }.prefix(maximumBillReminders))
    }

    private static func dailyReminders(
        preferences: ReminderPreferences,
        loggedToday: Bool,
        now: Date,
        calendar: Calendar
    ) -> [PlannedReminder] {
        (0..<dailyReminderDays).compactMap { offset in
            guard !(offset == 0 && loggedToday),
                  let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let fireDate = time(preferences.dailyMinute, onDayOf: day, calendar: calendar),
                  fireDate > now else { return nil }
            return PlannedReminder(
                identifier: identifierPrefix + "daily.\(dayKey(day, calendar: calendar))",
                fireDate: fireDate,
                message: .dailyLog,
                route: .log
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

/// The app's single owner of local notifications. It schedules only what the
/// plan asks for, changes only what differs, and never sends anything off the
/// device.
@MainActor
@Observable
final class ReminderCenter: NSObject {
    static let shared = ReminderCenter()

    /// Bumped whenever the preferences change, so the app re-plans.
    private(set) var revision: UInt64 = 0
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored private var scheduled: [String: PlannedReminder]?
    /// A tapped notification's destination, waiting for the app to take it.
    private(set) var pendingRoute: PlannedReminder.Route?

    private var center: UNUserNotificationCenter { .current() }

    /// Installed at launch so a tap that launches the app is not lost.
    func install() {
        center.delegate = self
    }

    func preferencesDidChange() {
        revision &+= 1
    }

    // UserNotifications values are not Sendable on every supported SDK, so
    // the completion-handler forms hand only Sendable values to the main actor.
    func refreshAuthorization() async {
        let center = center
        authorization = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Asks once, when the user first turns a reminder on.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        let center = center
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // No badge: MoneyUp never sets one, so iOS shouldn't ask for it.
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                continuation.resume()
            }
        }
        await refreshAuthorization()
    }

    private func pendingReminderIdentifiers() async -> [String] {
        let center = center
        return await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier).filter {
                    $0.hasPrefix(ReminderPlanner.identifierPrefix)
                })
            }
        }
    }

    func takePendingRoute() -> PlannedReminder.Route? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    /// Makes the pending notifications match `plan` exactly.
    func sync(_ plan: [PlannedReminder]) async {
        if scheduled == nil {
            // First sync of this launch: learn what an earlier launch left.
            let pending = await pendingReminderIdentifiers()
            scheduled = [:]
            center.removePendingNotificationRequests(withIdentifiers: pending)
        }
        let wanted = Dictionary(plan.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = (scheduled ?? [:]).keys.filter { wanted[$0] == nil }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for reminder in plan where scheduled?[reminder.identifier] != reminder {
            let request = UNNotificationRequest(
                identifier: reminder.identifier,
                content: content(for: reminder),
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: reminder.fireDate
                    ),
                    repeats: false
                )
            )
            schedule(request)
        }
        scheduled = wanted
    }

    /// Synchronous on purpose: the async form would move a request that is not
    /// Sendable on every SDK. Added in order; a failure leaves only that one
    /// reminder unscheduled.
    private func schedule(_ request: UNNotificationRequest) {
        center.add(request, withCompletionHandler: nil)
    }

    func removeAll() async {
        await sync([])
    }

    private func content(for reminder: PlannedReminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch reminder.message {
        case let .due(kind):
            content.title = AppLocalization.string(kind == .income ? "reminder.income_due" : "reminder.payment_due")
            content.body = AppLocalization.string("reminder.due_body")
            content.threadIdentifier = "moneyup.reminder.due"
        case let .dueDetail(kind, name, amount):
            content.title = String(format: AppLocalization.string("reminder.due_detail_title_format"), name)
            content.body = String(
                format: AppLocalization.string(kind == .income ? "reminder.income_detail_format" : "reminder.payment_detail_format"),
                formattedMoneyForNotification(amount)
            )
            content.threadIdentifier = "moneyup.reminder.due"
        case .dailyLog:
            content.title = AppLocalization.string("reminder.daily_title")
            content.body = AppLocalization.string("reminder.daily_body")
            content.threadIdentifier = "moneyup.reminder.daily"
        }
        content.sound = .default
        content.interruptionLevel = .active
        // In a scheduled summary, what is due ranks above the daily nudge.
        content.relevanceScore = reminder.route == .today ? 0.8 : 0.2
        content.userInfo = ["route": reminder.route.rawValue]
        return content
    }
}

extension ReminderCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let rawRoute = response.notification.request.content.userInfo["route"] as? String
        completionHandler()
        guard identifier.hasPrefix(ReminderPlanner.identifierPrefix),
              let rawRoute, let route = PlannedReminder.Route(rawValue: rawRoute) else { return }
        Task { @MainActor in
            ReminderCenter.shared.open(route)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // In the app, a logging nudge is noise; a due payment is still news.
        let isDaily = notification.request.identifier.hasPrefix(ReminderPlanner.identifierPrefix + "daily.")
        completionHandler(isDaily ? [] : [.banner, .list, .sound])
    }

    /// The main scene takes it: Log goes through the same reviewed broker as
    /// a widget tap, so it opens without Face ID only while the book is covered.
    private func open(_ route: PlannedReminder.Route) {
        pendingRoute = route
    }
}

extension AppModel {
    /// Plans reminders from the open book and makes them pending. A book
    /// that has gone (onboarding) takes its reminders with it.
    func refreshReminders() async {
        let reminders = ReminderCenter.shared
        switch state {
        case .onboarding:
            await reminders.removeAll()
        case .ready:
            let preferences = ReminderPreferences.load()
            guard preferences.isAnyEnabled else {
                await reminders.removeAll()
                return
            }
            let now = currentDateForUserAction()
            let calendar = reportingCalendar
            let loggedToday = journalRecentEntriesAreCurrent
                && entries.contains { calendar.isDate($0.occurredAt, inSameDayAs: now) }
            await reminders.sync(ReminderPlanner.plan(
                preferences: preferences,
                schedules: scheduledTransactions,
                loggedToday: loggedToday,
                now: now,
                calendar: calendar
            ))
        case .launching, .locked, .failed:
            return
        }
    }
}
