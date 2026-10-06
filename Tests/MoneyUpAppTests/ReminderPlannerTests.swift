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

    private func expectSoonestFirst(_ reminders: [PlannedReminder], file: StaticString = #filePath, line: UInt = #line) {
        let dates = reminders.map(\.fireDate)
        XCTAssertEqual(dates, dates.sorted(), "The soonest come first", file: file, line: line)
        XCTAssertEqual(Set(reminders.map(\.identifier)).count, reminders.count, "Identifiers are unique", file: file, line: line)
    }

    // MARK: Scheduled payments and income

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
        XCTAssertEqual(reminders.map(\.message), [.due(.expense, leadDays: 0), .due(.expense, leadDays: 0)])
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
        XCTAssertEqual(generic.message, .due(.income, leadDays: 0))

        preferences.showsDetails = true
        let detailed = try XCTUnwrap(plan(preferences, schedules: [salary], now: date(2026, 9, 29)).first)
        XCTAssertEqual(
            detailed.message,
            .dueDetail(.income, leadDays: 0, name: "Salary", amount: salary.amount)
        )
        // Identifiers are internal, yet they still carry nothing personal.
        XCTAssertFalse(detailed.identifier.contains("Salary"))
        XCTAssertFalse(detailed.identifier.contains("1800"))
    }

    func testLeadDaysRemindBeforeTheDueDate() throws {
        let rent = try schedule("Rent", next: date(2026, 10, 10), frequency: .yearly)
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.billLeadDays = [0, 1, 7]
        let reminders = plan(preferences, schedules: [rent], now: date(2026, 9, 29, 12))
        XCTAssertEqual(reminders.map(\.fireDate), [date(2026, 10, 3, 9), date(2026, 10, 9, 9), date(2026, 10, 10, 9)])
        XCTAssertEqual(reminders.map(\.message), [
            .due(.expense, leadDays: 7), .due(.expense, leadDays: 1), .due(.expense, leadDays: 0)
        ])
        expectSoonestFirst(reminders)
    }

    func testALeadReminderWhoseTimeHasPassedIsDropped() throws {
        let rent = try schedule("Rent", next: date(2026, 10, 1), frequency: .yearly)
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.billLeadDays = [0, 1]
        // Tomorrow's item: the day-before nudge was due at 9:00 today.
        let reminders = plan(preferences, schedules: [rent], now: date(2026, 9, 30, 10))
        XCTAssertEqual(reminders.map(\.fireDate), [date(2026, 10, 1, 9)])
        XCTAssertEqual(reminders.map(\.message), [.due(.expense, leadDays: 0)])
    }

    func testLeadRemindersReachOccurrencesBeyondTheHorizon() throws {
        // Due 40 days out, past the 35-day horizon, yet its week-before nudge
        // falls inside it.
        let insurance = try schedule("Insurance", next: date(2026, 11, 8), frequency: .yearly)
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.billLeadDays = [0, 7]
        let reminders = plan(preferences, schedules: [insurance], now: date(2026, 9, 29, 12))
        XCTAssertEqual(reminders.map(\.fireDate), [date(2026, 11, 1, 9)])
        XCTAssertEqual(reminders.map(\.message), [.due(.expense, leadDays: 7)])
    }

    func testIncomeCanBeLeftOut() throws {
        let salary = try schedule("Salary", kind: .income, next: date(2026, 10, 1), frequency: .yearly)
        let rent = try schedule("Rent", next: date(2026, 10, 1), frequency: .yearly)
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        let both = plan(preferences, schedules: [salary, rent], now: date(2026, 9, 29, 12)).map(\.message)
        XCTAssertEqual(both.count, 2)
        XCTAssertTrue(both.contains(.due(.income, leadDays: 0)))
        XCTAssertTrue(both.contains(.due(.expense, leadDays: 0)))

        preferences.includesIncome = false
        let expenseOnly = plan(preferences, schedules: [salary, rent], now: date(2026, 9, 29, 12))
        XCTAssertEqual(expenseOnly.map(\.message), [.due(.expense, leadDays: 0)])
    }

    // MARK: Daily logging

    func testDailyReminderCoversAWeekAndSkipsATodayAlreadyLogged() {
        var preferences = ReminderPreferences()
        preferences.dailyEnabled = true
        preferences.dailyMinutes = [20 * 60]
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

    func testTheDailyReminderCanKeepGoingAfterATodayAlreadyLogged() {
        var preferences = ReminderPreferences()
        preferences.dailyEnabled = true
        preferences.dailySkipsWhenLogged = false
        let reminders = plan(preferences, loggedToday: true, now: date(2026, 9, 29, 9))
        XCTAssertEqual(reminders.count, ReminderPlanner.dailyReminderDays)
        XCTAssertEqual(reminders.first?.fireDate, date(2026, 9, 29, 20))
    }

    func testSeveralDailyTimesEachFireEveryDay() {
        var preferences = ReminderPreferences()
        preferences.dailyEnabled = true
        preferences.dailyMinutes = [8 * 60, 12 * 60 + 30, 20 * 60]
        let reminders = plan(preferences, now: date(2026, 9, 29, 9))
        // Today's 8:00 has passed; the other six days ring three times each.
        XCTAssertEqual(reminders.count, 2 + 6 * 3)
        XCTAssertEqual(reminders.first?.fireDate, date(2026, 9, 29, 12, 30))
        XCTAssertTrue(reminders.allSatisfy { $0.message == .dailyLog })
        expectSoonestFirst(reminders)

        // A day already logged loses all of its reminders, not just one.
        let logged = plan(preferences, loggedToday: true, now: date(2026, 9, 29, 9))
        XCTAssertEqual(logged.count, 6 * 3)
        XCTAssertEqual(logged.first?.fireDate, date(2026, 9, 30, 8))
    }

    func testTheSameTimeChosenTwiceStillGivesOneReminder() {
        var preferences = ReminderPreferences()
        preferences.dailyEnabled = true
        // Not reachable through the screen, but a stored value must not collide.
        preferences.dailyMinutes = [20 * 60, 20 * 60]
        let reminders = plan(preferences, now: date(2026, 9, 29, 9))
        XCTAssertEqual(reminders.count, ReminderPlanner.dailyReminderDays)
        expectSoonestFirst(reminders)
    }

    func testDailyRemindersOnlyRingOnTheChosenDays() {
        var preferences = ReminderPreferences()
        preferences.dailyEnabled = true
        preferences.dailyWeekdays = [2, 3, 4, 5, 6]
        // Tuesday 29 September 2026: the week ahead has two weekend days.
        let reminders = plan(preferences, now: date(2026, 9, 29, 9))
        XCTAssertEqual(reminders.count, 5)
        for reminder in reminders {
            let weekday = calendar.component(.weekday, from: reminder.fireDate)
            XCTAssertTrue((2...6).contains(weekday), "Weekend reminder: \(reminder.fireDate)")
        }
    }

    // MARK: Weekly review

    func testTheWeeklyReviewFiresOnTheChosenWeekday() {
        var preferences = ReminderPreferences()
        preferences.weeklyEnabled = true
        preferences.weeklyWeekday = 1
        preferences.weeklyMinute = 19 * 60
        let reminders = plan(preferences, now: date(2026, 9, 29, 9))
        XCTAssertEqual(reminders.map(\.fireDate), [
            date(2026, 10, 4, 19), date(2026, 10, 11, 19), date(2026, 10, 18, 19), date(2026, 10, 25, 19)
        ])
        XCTAssertTrue(reminders.allSatisfy { $0.message == .weeklyReview })
        XCTAssertEqual(Set(reminders.map(\.route)), [.today])
        XCTAssertTrue(reminders.allSatisfy { $0.identifier.hasPrefix("moneyup.reminder.weekly.") })
        expectSoonestFirst(reminders)
    }

    func testTheWeeklyReviewSkipsAWeekdayEveningThatHasPassed() {
        var preferences = ReminderPreferences()
        preferences.weeklyEnabled = true
        preferences.weeklyWeekday = 1
        // Sunday 4 October, after the review time.
        let reminders = plan(preferences, now: date(2026, 10, 4, 20))
        XCTAssertEqual(reminders.first?.fireDate, date(2026, 10, 11, 19))
        XCTAssertEqual(reminders.count, ReminderPlanner.weeklyReminderWeeks - 1)
    }

    // MARK: Limits, style and identifiers

    func testDueRemindersStayWithinTheSystemLimit() throws {
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.billLeadDays = Set(ReminderPreferences.leadDayChoices)
        preferences.dailyEnabled = true
        preferences.dailyMinutes = [8 * 60, 12 * 60, 20 * 60]
        preferences.weeklyEnabled = true
        let weekly = try (0..<20).map { index in
            try schedule("Item \(index)", next: date(2026, 9, 30 - index % 5), frequency: .weekly)
        }
        let reminders = plan(preferences, schedules: weekly, now: date(2026, 9, 25, 7))
        XCTAssertLessThanOrEqual(reminders.filter { $0.route == .today && $0.message != .weeklyReview }.count,
                                 ReminderPlanner.maximumBillReminders)
        // iOS keeps 64 pending notifications per app; a few places stay free
        // for snoozed and test reminders.
        XCTAssertEqual(reminders.count, ReminderPlanner.maximumPendingReminders)
        XCTAssertLessThan(ReminderPlanner.maximumPendingReminders, 64)
        expectSoonestFirst(reminders)
    }

    func testEveryReminderCarriesTheChosenStyle() throws {
        let rent = try schedule("Rent", next: date(2026, 10, 1), frequency: .yearly)
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.dailyEnabled = true
        preferences.weeklyEnabled = true
        let loud = plan(preferences, schedules: [rent], now: date(2026, 9, 29, 12))
        XCTAssertFalse(loud.isEmpty)
        XCTAssertTrue(loud.allSatisfy { $0.style == ReminderStyle(playsSound: true, allowsSnooze: true) })

        preferences.playsSound = false
        preferences.allowsSnooze = false
        let quiet = plan(preferences, schedules: [rent], now: date(2026, 9, 29, 12))
        XCTAssertTrue(quiet.allSatisfy { $0.style == ReminderStyle(playsSound: false, allowsSnooze: false) })
        // Same reminders, so the centre swaps them in place rather than adding.
        XCTAssertEqual(quiet.map(\.identifier), loud.map(\.identifier))
        XCTAssertNotEqual(quiet, loud)
    }

    func testMessagesKnowWhatTheyCarryAndHowTheyRank() throws {
        let amount = try Money(Decimal(20), currency: try CurrencyCode("SGD"))
        let detail = ReminderMessage.dueDetail(.expense, leadDays: 1, name: "Rent", amount: amount)
        XCTAssertTrue(detail.carriesDetails)
        for message in [ReminderMessage.due(.income, leadDays: 0), .dailyLog, .weeklyReview, .test] {
            XCTAssertFalse(message.carriesDetails)
        }
        XCTAssertGreaterThan(detail.relevance, ReminderMessage.weeklyReview.relevance)
        XCTAssertGreaterThan(ReminderMessage.weeklyReview.relevance, ReminderMessage.dailyLog.relevance)
    }

    func testTimesOutsideTheDayCannotBePlanned() {
        XCTAssertNil(ReminderPlanner.time(-1, onDayOf: date(2026, 9, 29), calendar: calendar))
        XCTAssertNil(ReminderPlanner.time(24 * 60, onDayOf: date(2026, 9, 29), calendar: calendar))
        XCTAssertEqual(ReminderPlanner.time(0, onDayOf: date(2026, 9, 29, 15), calendar: calendar), date(2026, 9, 29))
        XCTAssertEqual(
            ReminderPlanner.time(24 * 60 - 1, onDayOf: date(2026, 9, 29, 15), calendar: calendar),
            date(2026, 9, 29, 23, 59)
        )
    }

    /// UserNotifications answers on its own queue. A fresh center's first
    /// sync reads the pending requests there, which trapped at launch when
    /// the reply inherited main-actor isolation (Xcode 16 SDK builds).
    @MainActor
    func testTheFirstSyncReadsPendingRequestsOffTheMainActor() async {
        let center = ReminderCenter()
        await center.sync([], preferences: ReminderPreferences())
        await center.refreshAuthorization()
    }
}
