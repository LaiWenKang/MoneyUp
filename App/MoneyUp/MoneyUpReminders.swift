import Foundation
import MoneyUpCore
import Observation
import UIKit
import UserNotifications

/// The app's single owner of local notifications. It schedules only what the
/// plan asks for, changes only what differs, and never sends anything off the
/// device.
@MainActor
@Observable
final class ReminderCenter: NSObject {
    static let shared = ReminderCenter()
    nonisolated static let testIdentifier = ReminderPlanner.identifierPrefix + "test"

    /// Bumped whenever the preferences change, so the app re-plans.
    private(set) var revision: UInt64 = 0
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored private var scheduled: [String: PlannedReminder]?
    @ObservationIgnored private var syncedPreferences: ReminderPreferences?
    @ObservationIgnored private var categoryLanguage: String?
    /// A tapped notification's destination, waiting for the app to take it.
    private(set) var pendingRoute: PlannedReminder.Route?

    private var center: UNUserNotificationCenter { .current() }

    /// Installed at launch so a tap that launches the app is not lost.
    func install() {
        center.delegate = self
        registerSnoozeCategory()
    }

    func preferencesDidChange() {
        revision &+= 1
    }

    /// Whether iOS will deliver a reminder right now.
    var canNotify: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
    }

    // UserNotifications values are not Sendable on every supported SDK, so
    // the completion-handler forms hand only Sendable values to the main actor.
    // UserNotifications replies on its own queue, so each reply is @Sendable:
    // one that inherited main-actor isolation would trap there.
    func refreshAuthorization() async {
        let center = center
        authorization = await withCheckedContinuation { continuation in
            center.getNotificationSettings { @Sendable settings in
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
            center.requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in
                continuation.resume()
            }
        }
        await refreshAuthorization()
    }

    private func pendingReminderIdentifiers() async -> [String] {
        let center = center
        return await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { @Sendable requests in
                continuation.resume(returning: requests.map { $0.identifier }.filter {
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
    func sync(_ plan: [PlannedReminder], preferences: ReminderPreferences) async {
        registerSnoozeCategory()
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
        if syncedPreferences != preferences {
            syncedPreferences = preferences
            await discardStaleSnoozes(preferences)
        }
    }

    /// Synchronous on purpose: the async form would move a request that is not
    /// Sendable on every SDK. Added in order; a failure leaves only that one
    /// reminder unscheduled.
    private func schedule(_ request: UNNotificationRequest) {
        center.add(request, withCompletionHandler: nil)
    }

    /// Takes everything back, including reminders the person snoozed.
    func removeAll() async {
        await sync([], preferences: ReminderPreferences())
    }

    /// Shows one reminder in a few seconds so the wording, sound and buttons
    /// can be seen before relying on them.
    func sendTest(style: ReminderStyle) {
        let reminder = PlannedReminder(
            identifier: Self.testIdentifier,
            fireDate: Date(),
            message: .test,
            route: .today,
            style: style
        )
        schedule(UNNotificationRequest(
            identifier: reminder.identifier,
            content: content(for: reminder),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        ))
    }

    /// The snooze buttons, titled in the language the app is showing.
    private func registerSnoozeCategory() {
        let language = AppLanguagePreference.current.rawValue
        guard categoryLanguage != language else { return }
        categoryLanguage = language
        let actions = ReminderSnooze.allCases.map {
            UNNotificationAction(identifier: $0.rawValue, title: AppLocalization.string($0.titleKey), options: [])
        }
        center.setNotificationCategories([UNNotificationCategory(
            identifier: ReminderSnooze.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )])
    }

    /// A snoozed copy keeps the words it was made with, so it goes as soon as
    /// the choice that allowed those words is turned off.
    private func discardStaleSnoozes(_ preferences: ReminderPreferences) async {
        let center = center
        let pending: [ReminderSnooze.Pending] = await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { @Sendable requests in
                continuation.resume(returning: requests.filter {
                    $0.identifier.hasPrefix(ReminderSnooze.requestPrefix)
                }.map {
                    ReminderSnooze.Pending(
                        identifier: $0.identifier,
                        carriesDetails: ($0.content.userInfo["details"] as? Bool) ?? true
                    )
                })
            }
        }
        let discarded = ReminderSnooze.discarded(pending, preferences: preferences)
        if !discarded.isEmpty { center.removePendingNotificationRequests(withIdentifiers: discarded) }
    }

    private func content(for reminder: PlannedReminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = ReminderText.title(for: reminder.message)
        content.body = ReminderText.body(for: reminder.message)
        content.threadIdentifier = ReminderText.thread(for: reminder.message)
        content.sound = reminder.style.playsSound ? .default : nil
        content.interruptionLevel = .active
        // In a scheduled summary, what is due ranks above the nudges.
        content.relevanceScore = reminder.message.relevance
        content.userInfo = ["route": reminder.route.rawValue, "details": reminder.message.carriesDetails]
        if reminder.style.allowsSnooze {
            content.categoryIdentifier = ReminderSnooze.categoryIdentifier
        }
        return content
    }
}

extension ReminderCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let outcome = ReminderResponse.decide(
            actionIdentifier: response.actionIdentifier,
            isDefaultAction: response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            requestIdentifier: request.identifier,
            rawRoute: request.content.userInfo["route"] as? String
        )
        switch outcome {
        case let .snooze(snooze):
            // Added before replying, in this same call: the app may be
            // suspended the moment the reply is made.
            Self.repeatLater(request, snooze: snooze, center: center)
            completionHandler()
        case let .open(route):
            completionHandler()
            Task { @MainActor in
                ReminderCenter.shared.open(route)
            }
        case .ignore:
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(
            ReminderResponse.showsInForeground(notification.request.identifier) ? [.banner, .list, .sound] : []
        )
    }

    /// The same words and route again, later. It replaces an earlier snooze of
    /// the same reminder rather than piling up.
    private nonisolated static func repeatLater(
        _ original: UNNotificationRequest,
        snooze: ReminderSnooze,
        center: UNUserNotificationCenter
    ) {
        let now = Date()
        guard let fireDate = snooze.fireDate(from: now, calendar: .current),
              let content = original.content.mutableCopy() as? UNMutableNotificationContent else { return }
        center.add(
            UNNotificationRequest(
                identifier: ReminderSnooze.requestIdentifier(snoozing: original.identifier),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, fireDate.timeIntervalSince(now)),
                    repeats: false
                )
            ),
            withCompletionHandler: nil
        )
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
            await reminders.sync(
                ReminderPlanner.plan(
                    preferences: preferences,
                    schedules: scheduledTransactions,
                    loggedToday: loggedToday,
                    now: now,
                    calendar: calendar
                ),
                preferences: preferences
            )
        case .launching, .locked, .failed:
            return
        }
    }
}
