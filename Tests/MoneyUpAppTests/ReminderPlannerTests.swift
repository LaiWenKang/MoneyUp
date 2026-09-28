import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

/// Reminders are planned from the book without any clock or notification
/// centre, so every rule about what fires, when, and what it may say is pinned
/// here.
final class ReminderPlannerTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func schedule(
        _ name: String,
        kind: JournalEntryKind = .expense,
        next: Date,
        frequency: RecurrenceFrequency = .monthly,
        isActive: Bool = true
    ) throws -> ScheduledTransaction {
        try ScheduledTransaction(
            kind: kind,
            name: name,
            amount: try Money(Decimal(1_800), currency: try CurrencyCode("SGD")),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: next,
            frequency: frequency,
            isActive: isActive,
            recurrenceTimeZoneIdentifier: "Asia/Singapore"
        )
    }

    private func plan(
        _ preferences: ReminderPreferences,
        schedules: [ScheduledTransaction] = [],
        loggedToday: Bool = false,
        now: Date
    ) -> [PlannedReminder] {
        ReminderPlanner.plan(
            preferences: preferences,
            schedules: schedules,
            loggedToday: loggedToday,
            now: now,
            calendar: calendar
        )
    }

    func testNothingIsPlannedWhileRemindersAreOff() throws {
        let rent = try schedule("Rent", next: date(2026, 10, 1))
        XCTAssertEqual(plan(ReminderPreferences(), schedules: [rent], now: date(2026, 9, 29, 8)), [])
    }

    func testDueItemsFireOnTheirDayAtTheChosenTime() throws {
        let rent = try schedule("Rent", next: date(2026, 10, 1))
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.billMinute = 8 * 60 + 30
        let reminders = plan(preferences, schedules: [rent], now: date(2026, 9, 29, 12))
        XCTAssertEqual(reminders.map(\.fireDate), [date(2026, 10, 1, 8, 30), date(2026, 11, 1, 8, 30)])
        XCTAssertEqual(Set(reminders.map(\.route)), [.today])
        XCTAssertEqual(Set(reminders.map(\.identifier)).count, reminders.count)
    }

    func testPastTimesAndPausedSchedulesStaySilent() throws {
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        // Due today, but 9:00 has passed; overdue items are reviewed in the app.
        let today = try schedule("Phone", next: date(2026, 9, 29), frequency: .yearly)
        let overdue = try schedule("Gym", next: date(2026, 9, 20), frequency: .yearly)
        let paused = try schedule("Club", next: date(2026, 10, 3), isActive: false)
        XCTAssertEqual(plan(preferences, schedules: [today, overdue, paused], now: date(2026, 9, 29, 10)), [])
    }

    func testNamesAndAmountsAppearOnlyWhenChosen() throws {
        let salary = try schedule("Salary", kind: .income, next: date(2026, 10, 1))
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        let generic = try XCTUnwrap(plan(preferences, schedules: [salary], now: date(2026, 9, 29)).first)
        XCTAssertEqual(generic.message, .due(.income))

        preferences.showsDetails = true
        let detailed = try XCTUnwrap(plan(preferences, schedules: [salary], now: date(2026, 9, 29)).first)
        XCTAssertEqual(detailed.message, .dueDetail(.income, name: "Salary", amount: salary.amount))
        // Identifiers are internal, yet they still carry nothing personal.
        XCTAssertFalse(detailed.identifier.contains("Salary"))
        XCTAssertFalse(detailed.identifier.contains("1800"))
    }

    func testDailyReminderCoversAWeekAndSkipsATodayAlreadyLogged() {
        var preferences = ReminderPreferences()
        preferences.dailyEnabled = true
        preferences.dailyMinute = 20 * 60
        let morning = date(2026, 9, 29, 9)
        let week = plan(preferences, now: morning)
        XCTAssertEqual(week.count, ReminderPlanner.dailyReminderDays)
        XCTAssertEqual(week.first?.fireDate, date(2026, 9, 29, 20))
        XCTAssertEqual(Set(week.map(\.route)), [.log])

        let logged = plan(preferences, loggedToday: true, now: morning)
        XCTAssertEqual(logged.first?.fireDate, date(2026, 9, 30, 20))
        XCTAssertEqual(logged.count, ReminderPlanner.dailyReminderDays - 1)
        // After tonight's time, tomorrow is the first reminder either way.
        XCTAssertEqual(plan(preferences, now: date(2026, 9, 29, 21)).first?.fireDate, date(2026, 9, 30, 20))
    }

    func testDueRemindersStayWithinTheSystemLimit() throws {
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.dailyEnabled = true
        let weekly = try (0..<20).map { index in
            try schedule("Item \(index)", next: date(2026, 9, 30 - index % 5), frequency: .weekly)
        }
        let reminders = plan(preferences, schedules: weekly, now: date(2026, 9, 25, 7))
        XCTAssertLessThanOrEqual(reminders.filter { $0.route == .today }.count, ReminderPlanner.maximumBillReminders)
        // iOS keeps 64 pending notifications per app.
        XCTAssertLessThanOrEqual(reminders.count, 64)
        let dueDates = reminders.filter { $0.route == .today }.map(\.fireDate)
        XCTAssertEqual(dueDates, dueDates.sorted(), "The soonest are kept")
    }

    func testPreferencesPersistOnThisDeviceOnly() throws {
        let suite = "moneyup.reminder-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReminderPreferences.load(from: defaults), ReminderPreferences())
        var preferences = ReminderPreferences()
        preferences.dailyEnabled = true
        preferences.dailyMinute = 21 * 60 + 15
        preferences.save(to: defaults)
        XCTAssertEqual(ReminderPreferences.load(from: defaults), preferences)
    }
}
