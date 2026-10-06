import Foundation
@testable import MoneyUp
import XCTest

/// The reminder choices are stored on this iPhone between launches and across
/// updates, so what loads, what is corrected and what the screen may change
/// are pinned here.
final class ReminderPreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "moneyup.reminder-preference-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func decode(_ json: String) throws -> ReminderPreferences {
        try JSONDecoder().decode(ReminderPreferences.self, from: Data(json.utf8))
    }

    // MARK: Storage

    func testPreferencesPersistOnThisDeviceOnly() throws {
        try withDefaults { defaults in
            XCTAssertEqual(ReminderPreferences.load(from: defaults), ReminderPreferences())
            var preferences = ReminderPreferences()
            preferences.billsEnabled = true
            preferences.billLeadDays = [0, 3, 7]
            preferences.includesIncome = false
            preferences.dailyEnabled = true
            preferences.dailyMinutes = [8 * 60, 21 * 60 + 15]
            preferences.dailyWeekdays = [2, 4, 6]
            preferences.dailySkipsWhenLogged = false
            preferences.weeklyEnabled = true
            preferences.weeklyWeekday = 7
            preferences.weeklyMinute = 10 * 60
            preferences.showsDetails = true
            preferences.playsSound = false
            preferences.allowsSnooze = false
            preferences.save(to: defaults)
            XCTAssertEqual(ReminderPreferences.load(from: defaults), preferences)
        }
    }

    func testMissingOrDamagedStorageLoadsTheDefaults() throws {
        try withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: ReminderPreferences.storageKey)
            XCTAssertEqual(ReminderPreferences.load(from: defaults), ReminderPreferences())
            defaults.set(Data("[1, 2]".utf8), forKey: ReminderPreferences.storageKey)
            XCTAssertEqual(ReminderPreferences.load(from: defaults), ReminderPreferences())
        }
    }

    func testChoicesSavedByTheFirstBuildsStillLoad() throws {
        // What 0.7.3 (1077.1) stored: a single daily time and no other choices.
        let json = """
        {"billsEnabled":true,"billMinute":510,"dailyEnabled":true,"dailyMinute":1290,"showsDetails":true}
        """
        var expected = ReminderPreferences()
        expected.billsEnabled = true
        expected.billMinute = 510
        expected.dailyEnabled = true
        expected.dailyMinutes = [1290]
        expected.showsDetails = true
        let loaded = try decode(json)
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(loaded.billLeadDays, [0])
        XCTAssertTrue(loaded.includesIncome)
        XCTAssertEqual(loaded.dailyWeekdays, ReminderPreferences.allWeekdays)
        XCTAssertTrue(loaded.dailySkipsWhenLogged)
        XCTAssertFalse(loaded.weeklyEnabled)
        XCTAssertTrue(loaded.playsSound)
        XCTAssertTrue(loaded.allowsSnooze)
    }

    func testAnEmptyOrPartialRecordFillsInTheRest() throws {
        XCTAssertEqual(try decode("{}"), ReminderPreferences())
        let partial = try decode(#"{"weeklyEnabled":true,"weeklyWeekday":6}"#)
        XCTAssertTrue(partial.weeklyEnabled)
        XCTAssertEqual(partial.weeklyWeekday, 6)
        XCTAssertEqual(partial.weeklyMinute, ReminderPreferences.defaultWeeklyMinute)
    }

    func testValuesNobodyCouldHaveChosenFallBackToTheDefaults() throws {
        let json = """
        {"billMinute":5000,"billLeadDays":[0,5,99],"dailyMinutes":[1300,1300,-5,20,30,40],
         "dailyWeekdays":[9],"weeklyWeekday":0,"weeklyMinute":-1}
        """
        let loaded = try decode(json)
        XCTAssertEqual(loaded.billMinute, ReminderPreferences.defaultBillMinute)
        XCTAssertEqual(loaded.billLeadDays, [0], "Only the offered choices survive")
        XCTAssertEqual(loaded.dailyMinutes, [1300, 20, 30], "Valid, distinct, at most three")
        XCTAssertEqual(loaded.dailyWeekdays, ReminderPreferences.allWeekdays)
        XCTAssertEqual(loaded.weeklyWeekday, 1)
        XCTAssertEqual(loaded.weeklyMinute, ReminderPreferences.defaultWeeklyMinute)

        let empty = try decode(#"{"billLeadDays":[],"dailyMinutes":[],"dailyWeekdays":[]}"#)
        XCTAssertEqual(empty.billLeadDays, [0])
        XCTAssertEqual(empty.dailyMinutes, [ReminderPreferences.defaultDailyMinute])
        XCTAssertEqual(empty.dailyWeekdays, ReminderPreferences.allWeekdays)
    }

    // MARK: What the screen may change

    func testALeadDayCanBeTickedOnAndOffButOneAlwaysStays() {
        var preferences = ReminderPreferences()
        XCTAssertEqual(preferences.billLeadDays, [0])
        preferences.toggleLeadDay(0)
        XCTAssertEqual(preferences.billLeadDays, [0], "The last one cannot be removed")
        preferences.toggleLeadDay(3)
        XCTAssertEqual(preferences.billLeadDays, [0, 3])
        preferences.toggleLeadDay(0)
        XCTAssertEqual(preferences.billLeadDays, [3])
        preferences.toggleLeadDay(5)
        XCTAssertEqual(preferences.billLeadDays, [3], "Only the offered choices can be ticked")
    }

    func testAtLeastOneWeekdayStaysOn() {
        var preferences = ReminderPreferences()
        for weekday in 1...6 { preferences.toggleDailyWeekday(weekday) }
        XCTAssertEqual(preferences.dailyWeekdays, [7])
        preferences.toggleDailyWeekday(7)
        XCTAssertEqual(preferences.dailyWeekdays, [7])
        preferences.toggleDailyWeekday(1)
        XCTAssertEqual(preferences.dailyWeekdays, [1, 7])
        preferences.toggleDailyWeekday(9)
        XCTAssertEqual(preferences.dailyWeekdays, [1, 7])
    }

    func testDailyTimesAreLimitedAndTheLastOneStays() {
        var preferences = ReminderPreferences()
        XCTAssertEqual(preferences.dailyMinutes, [ReminderPreferences.defaultDailyMinute])
        preferences.removeDailyTime(at: 0)
        XCTAssertEqual(preferences.dailyMinutes.count, 1, "Turn the reminder off instead")

        XCTAssertTrue(preferences.addDailyTime())
        XCTAssertEqual(preferences.dailyMinutes, [20 * 60, 12 * 60 + 30])
        XCTAssertTrue(preferences.addDailyTime())
        XCTAssertEqual(preferences.dailyMinutes, [20 * 60, 12 * 60 + 30, 8 * 60])
        XCTAssertFalse(preferences.addDailyTime(), "Three times a day is the most")
        XCTAssertEqual(preferences.dailyMinutes.count, ReminderPreferences.maximumDailyTimes)

        preferences.removeDailyTime(at: 7)
        XCTAssertEqual(preferences.dailyMinutes.count, 3, "An index that is not there changes nothing")
        preferences.removeDailyTime(at: 1)
        XCTAssertEqual(preferences.dailyMinutes, [20 * 60, 8 * 60])
        preferences.removeDailyTime(at: 0)
        preferences.removeDailyTime(at: 0)
        XCTAssertEqual(preferences.dailyMinutes, [8 * 60])
    }

    func testTheSuggestedExtraTimeIsOneNotAlreadyInUse() {
        var preferences = ReminderPreferences()
        preferences.dailyMinutes = [12 * 60 + 30]
        XCTAssertEqual(preferences.suggestedExtraDailyMinute, 8 * 60)
        preferences.dailyMinutes = [12 * 60 + 30, 8 * 60, 15 * 60, 18 * 60, 21 * 60]
        XCTAssertEqual(preferences.suggestedExtraDailyMinute, 12 * 60)
    }

    func testTimesAreTidiedWhenTheScreenCloses() {
        var preferences = ReminderPreferences()
        preferences.dailyMinutes = [20 * 60, 8 * 60, 8 * 60, 12 * 60 + 30]
        XCTAssertEqual(preferences.tidied().dailyMinutes, [8 * 60, 12 * 60 + 30, 20 * 60])
        XCTAssertEqual(preferences.tidied().tidied(), preferences.tidied())
    }

    func testCountingAndTurningOn() {
        var preferences = ReminderPreferences()
        XCTAssertEqual(preferences.enabledCount, 0)
        XCTAssertFalse(preferences.isAnyEnabled)
        let before = preferences

        preferences.billsEnabled = true
        XCTAssertEqual(preferences.enabledCount, 1)
        XCTAssertTrue(preferences.isAnyEnabled)
        XCTAssertTrue(preferences.turnsOnReminders(since: before), "Time to ask iOS for permission")

        let bills = preferences
        preferences.showsDetails = true
        XCTAssertFalse(preferences.turnsOnReminders(since: bills), "A different choice is not a new reminder")

        preferences.dailyEnabled = true
        preferences.weeklyEnabled = true
        XCTAssertEqual(preferences.enabledCount, 3)
        XCTAssertTrue(preferences.turnsOnReminders(since: bills), "Another kind was switched on")

        preferences.billsEnabled = false
        XCTAssertFalse(preferences.turnsOnReminders(since: preferences), "Nothing changed")
        XCTAssertFalse(ReminderPreferences().turnsOnReminders(since: preferences), "Turning off is not turning on")
    }

    func testTheStyleFollowsTheSoundAndSnoozeChoices() {
        var preferences = ReminderPreferences()
        XCTAssertEqual(preferences.style, ReminderStyle(playsSound: true, allowsSnooze: true))
        preferences.playsSound = false
        XCTAssertEqual(preferences.style, ReminderStyle(playsSound: false, allowsSnooze: true))
        preferences.allowsSnooze = false
        XCTAssertEqual(preferences.style, ReminderStyle(playsSound: false, allowsSnooze: false))
    }
}
