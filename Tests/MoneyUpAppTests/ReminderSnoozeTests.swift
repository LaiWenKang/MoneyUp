import Foundation
@testable import MoneyUp
import XCTest

/// The "remind me again" buttons and the rules for answering a reminder are
/// decided without a notification centre, so they are pinned here.
final class ReminderSnoozeTests: XCTestCase {
    private let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private let bill = "moneyup.reminder.bill.7B1C0F4A-0000-4000-8000-000000000001.20261001.0"
    private let daily = "moneyup.reminder.daily.20260929.1200"
    private let weekly = "moneyup.reminder.weekly.20261004"

    // MARK: Snoozing

    func testSnoozingWaitsAnHourOrUntilTomorrow() {
        let now = date(9, 29, 21, 5)
        XCTAssertEqual(ReminderSnooze.inOneHour.fireDate(from: now, calendar: newYork), now.addingTimeInterval(3_600))
        XCTAssertEqual(ReminderSnooze.tomorrow.fireDate(from: now, calendar: newYork), date(9, 30, 21, 5))
    }

    func testTomorrowKeepsTheSameClockTimeWhenTheClocksChange() throws {
        // US clocks go forward overnight on 8 March 2026: that day is 23 hours.
        let now = date(3, 7, 21)
        let tomorrow = try XCTUnwrap(ReminderSnooze.tomorrow.fireDate(from: now, calendar: newYork))
        XCTAssertEqual(tomorrow, date(3, 8, 21))
        XCTAssertEqual(tomorrow.timeIntervalSince(now), 23 * 3_600)
    }

    func testEachButtonIsNamedInBothLanguages() {
        let expected: [ReminderSnooze: (String, String)] = [
            .inOneHour: ("Remind in 1 hour", "1 小时后提醒"),
            .tomorrow: ("Remind tomorrow", "明天提醒")
        ]
        for snooze in ReminderSnooze.allCases {
            XCTAssertEqual(AppLocalization.string(snooze.titleKey, language: .english), expected[snooze]?.0)
            XCTAssertEqual(AppLocalization.string(snooze.titleKey, language: .simplifiedChinese), expected[snooze]?.1)
        }
        XCTAssertEqual(Set(ReminderSnooze.allCases.map(\.rawValue)).count, ReminderSnooze.allCases.count)
    }

    func testASnoozedCopyReplacesTheEarlierSnoozeOfTheSameReminder() {
        XCTAssertEqual(ReminderSnooze.requestIdentifier(snoozing: daily), "moneyup.snoozed.daily.20260929.1200")
        XCTAssertEqual(
            ReminderSnooze.requestIdentifier(snoozing: "moneyup.snoozed.daily.20260929.1200"),
            "moneyup.snoozed.daily.20260929.1200"
        )
        XCTAssertEqual(ReminderSnooze.requestIdentifier(snoozing: weekly), "moneyup.snoozed.weekly.20261004")
        XCTAssertEqual(ReminderSnooze.requestIdentifier(snoozing: "other"), "moneyup.snoozed.other")
        // Never under the planner's prefix, or a planning pass would remove it.
        XCTAssertFalse(ReminderSnooze.requestIdentifier(snoozing: bill).hasPrefix(ReminderPlanner.identifierPrefix))
    }

    func testAReminderIsKnownByItsIdentifier() {
        XCTAssertEqual(ReminderKind(identifier: bill), .bill)
        XCTAssertEqual(ReminderKind(identifier: daily), .daily)
        XCTAssertEqual(ReminderKind(identifier: weekly), .weekly)
        XCTAssertEqual(ReminderKind(identifier: "moneyup.snoozed.bill.abc.20261001.0"), .bill)
        XCTAssertEqual(ReminderKind(identifier: "moneyup.snoozed.daily.20260929.1200"), .daily)
        XCTAssertEqual(ReminderKind(identifier: ReminderCenter.testIdentifier), .test)
        XCTAssertEqual(ReminderKind(identifier: "moneyup.snoozed.test"), .test)
        XCTAssertNil(ReminderKind(identifier: "moneyup.reminder."))
        XCTAssertNil(ReminderKind(identifier: "com.example.other"))
    }

    // MARK: Which snoozed copies survive a change of choices

    private func everythingOn() -> ReminderPreferences {
        var preferences = ReminderPreferences()
        preferences.billsEnabled = true
        preferences.dailyEnabled = true
        preferences.weeklyEnabled = true
        preferences.showsDetails = true
        return preferences
    }

    private func snoozed() -> [ReminderSnooze.Pending] {
        [
            .init(identifier: "moneyup.snoozed.bill.abc.20261001.0", carriesDetails: true),
            .init(identifier: "moneyup.snoozed.daily.20260929.1200", carriesDetails: false),
            .init(identifier: "moneyup.snoozed.weekly.20261004", carriesDetails: false)
        ]
    }

    func testSnoozedCopiesStayWhileTheChoicesThatAllowedThemStay() {
        XCTAssertEqual(ReminderSnooze.discarded(snoozed(), preferences: everythingOn()), [])
        XCTAssertEqual(ReminderSnooze.discarded([], preferences: ReminderPreferences()), [])
    }

    func testTurningSnoozeOffTakesEverySnoozedCopyBack() {
        var preferences = everythingOn()
        preferences.allowsSnooze = false
        XCTAssertEqual(Set(ReminderSnooze.discarded(snoozed(), preferences: preferences)), Set(snoozed().map(\.identifier)))
    }

    func testTurningOneKindOffTakesOnlyItsSnoozedCopiesBack() {
        var preferences = everythingOn()
        preferences.dailyEnabled = false
        XCTAssertEqual(ReminderSnooze.discarded(snoozed(), preferences: preferences), ["moneyup.snoozed.daily.20260929.1200"])
        preferences.billsEnabled = false
        preferences.weeklyEnabled = false
        XCTAssertEqual(ReminderSnooze.discarded(snoozed(), preferences: preferences).count, 3)
    }

    func testTurningNamesOffTakesBackCopiesThatShowThem() {
        var preferences = everythingOn()
        preferences.showsDetails = false
        // The copy says what it said when it was made, so it cannot stay.
        XCTAssertEqual(ReminderSnooze.discarded(snoozed(), preferences: preferences), ["moneyup.snoozed.bill.abc.20261001.0"])
    }

    func testASnoozedTestReminderStaysOnlyWhileRemindersAndSnoozingAreOn() {
        let test = ReminderSnooze.Pending(identifier: "moneyup.snoozed.test", carriesDetails: false)
        XCTAssertEqual(ReminderSnooze.discarded([test], preferences: everythingOn()), [])
        var preferences = everythingOn()
        preferences.allowsSnooze = false
        XCTAssertEqual(ReminderSnooze.discarded([test], preferences: preferences), ["moneyup.snoozed.test"])
        XCTAssertEqual(ReminderSnooze.discarded([test], preferences: ReminderPreferences()), ["moneyup.snoozed.test"])
    }

    func testAnUnrecognisedSnoozedCopyIsTakenBack() {
        let stray = ReminderSnooze.Pending(identifier: "moneyup.snoozed.mystery", carriesDetails: false)
        XCTAssertEqual(ReminderSnooze.discarded([stray], preferences: everythingOn()), ["moneyup.snoozed.mystery"])
    }

    // MARK: Answering a reminder

    private func decide(
        action: String = "com.apple.UNNotificationDefaultActionIdentifier",
        isDefault: Bool = true,
        request: String,
        route: String?
    ) -> ReminderResponse {
        ReminderResponse.decide(
            actionIdentifier: action,
            isDefaultAction: isDefault,
            requestIdentifier: request,
            rawRoute: route
        )
    }

    func testTappingAReminderOpensItsDestination() {
        XCTAssertEqual(decide(request: daily, route: "log"), .open(.log))
        XCTAssertEqual(decide(request: bill, route: "today"), .open(.today))
        XCTAssertEqual(decide(request: "moneyup.snoozed.daily.20260929.1200", route: "log"), .open(.log))
        XCTAssertEqual(decide(request: ReminderCenter.testIdentifier, route: "today"), .open(.today))
    }

    func testTappingWithoutAKnownDestinationDoesNothing() {
        XCTAssertEqual(decide(request: daily, route: nil), .ignore)
        XCTAssertEqual(decide(request: daily, route: "somewhere"), .ignore)
    }

    func testAButtonSnoozesAndAnUnknownButtonDoesNothing() {
        XCTAssertEqual(
            decide(action: ReminderSnooze.inOneHour.rawValue, isDefault: false, request: daily, route: "log"),
            .snooze(.inOneHour)
        )
        XCTAssertEqual(
            decide(action: ReminderSnooze.tomorrow.rawValue, isDefault: false, request: bill, route: "today"),
            .snooze(.tomorrow)
        )
        XCTAssertEqual(decide(action: "com.apple.UNNotificationDismissActionIdentifier", isDefault: false, request: daily, route: "log"), .ignore)
        XCTAssertEqual(decide(action: "something.else", isDefault: false, request: daily, route: "log"), .ignore)
    }

    func testOnlyMoneyUpRemindersAreAnswered() {
        XCTAssertEqual(decide(request: "com.example.other", route: "log"), .ignore)
        XCTAssertEqual(
            decide(action: ReminderSnooze.tomorrow.rawValue, isDefault: false, request: "com.example.other", route: "log"),
            .ignore
        )
        XCTAssertTrue(ReminderResponse.isReminder(daily))
        XCTAssertTrue(ReminderResponse.isReminder("moneyup.snoozed.daily.20260929.1200"))
        XCTAssertFalse(ReminderResponse.isReminder("moneyup.other"))
    }

    func testOnlyDueItemsAndTestsShowWhileTheAppIsOpen() {
        XCTAssertTrue(ReminderResponse.showsInForeground(bill))
        XCTAssertTrue(ReminderResponse.showsInForeground("moneyup.snoozed.bill.abc.20261001.0"))
        XCTAssertTrue(ReminderResponse.showsInForeground(ReminderCenter.testIdentifier))
        XCTAssertFalse(ReminderResponse.showsInForeground(daily))
        XCTAssertFalse(ReminderResponse.showsInForeground(weekly))
        XCTAssertFalse(ReminderResponse.showsInForeground("moneyup.snoozed.daily.20260929.1200"))
    }
}
