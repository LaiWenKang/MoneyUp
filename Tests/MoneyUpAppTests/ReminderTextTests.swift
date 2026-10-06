import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

/// What a reminder says, in each language, and how the screen names days.
final class ReminderTextTests: XCTestCase {
    private var originalLanguage: String?

    private var languageDefaults: UserDefaults {
        guard let defaults = AppLanguagePreference.defaults else {
            fatalError("App Group defaults unavailable in reminder text tests")
        }
        return defaults
    }

    override func setUp() {
        super.setUp()
        originalLanguage = languageDefaults.string(forKey: AppLanguagePreference.storageKey)
    }

    override func tearDown() {
        if let originalLanguage {
            languageDefaults.set(originalLanguage, forKey: AppLanguagePreference.storageKey)
        } else {
            languageDefaults.removeObject(forKey: AppLanguagePreference.storageKey)
        }
        super.tearDown()
    }

    private func use(_ language: AppLanguagePreference) {
        languageDefaults.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
    }

    private func rent() throws -> Money {
        try Money(Decimal(1_800), currency: try CurrencyCode("SGD"))
    }

    @MainActor
    func testAnUpcomingItemCountsDownInEnglish() {
        use(.english)
        let titles = [
            ReminderText.title(for: .due(.expense, leadDays: 0)),
            ReminderText.title(for: .due(.expense, leadDays: 1)),
            ReminderText.title(for: .due(.expense, leadDays: 3)),
            ReminderText.title(for: .due(.income, leadDays: 0)),
            ReminderText.title(for: .due(.income, leadDays: 1)),
            ReminderText.title(for: .due(.income, leadDays: 7))
        ]
        XCTAssertEqual(titles, [
            "A payment is due today", "A payment is due tomorrow", "A payment is due in 3 days",
            "Income expected today", "Income expected tomorrow", "Income expected in 7 days"
        ])
        XCTAssertEqual(ReminderText.body(for: .due(.expense, leadDays: 3)), "Open MoneyUp to review it.")
    }

    @MainActor
    func testAnUpcomingItemCountsDownInChinese() {
        use(.simplifiedChinese)
        let titles = [
            ReminderText.title(for: .due(.expense, leadDays: 0)),
            ReminderText.title(for: .due(.expense, leadDays: 1)),
            ReminderText.title(for: .due(.expense, leadDays: 3)),
            ReminderText.title(for: .due(.income, leadDays: 1)),
            ReminderText.title(for: .due(.income, leadDays: 7))
        ]
        XCTAssertEqual(titles, [
            "今天有一笔付款到期", "明天有一笔付款到期", "3 天后有一笔付款到期",
            "明天有一笔预计收入", "7 天后有一笔预计收入"
        ])
    }

    @MainActor
    func testDetailsNameTheItemAndShowTheAmountOnlyInTheBody() throws {
        use(.english)
        let amount = try rent()
        let today = ReminderMessage.dueDetail(.expense, leadDays: 0, name: "Rent", amount: amount)
        let tomorrow = ReminderMessage.dueDetail(.expense, leadDays: 1, name: "Rent", amount: amount)
        let later = ReminderMessage.dueDetail(.expense, leadDays: 7, name: "Rent", amount: amount)
        XCTAssertEqual(ReminderText.title(for: today), "Rent is due today")
        XCTAssertEqual(ReminderText.title(for: tomorrow), "Rent is due tomorrow")
        XCTAssertEqual(ReminderText.title(for: later), "Rent is due in 7 days")
        let body = ReminderText.body(for: today)
        XCTAssertTrue(body.contains("SGD"), body)
        XCTAssertTrue(body.hasSuffix(" to pay"), body)
        XCTAssertFalse(ReminderText.title(for: later).contains("SGD"))

        let income = ReminderText.body(for: .dueDetail(.income, leadDays: 0, name: "Salary", amount: amount))
        XCTAssertTrue(income.hasSuffix(" expected"), income)

        use(.simplifiedChinese)
        XCTAssertEqual(ReminderText.title(for: today), "今天到期：Rent")
        XCTAssertEqual(ReminderText.title(for: tomorrow), "明天到期：Rent")
        XCTAssertEqual(ReminderText.title(for: later), "7 天后到期：Rent")
    }

    @MainActor
    func testEveryKindOfReminderReadsInBothLanguages() throws {
        let messages: [ReminderMessage] = [
            .due(.expense, leadDays: 2), .due(.income, leadDays: 0),
            .dueDetail(.expense, leadDays: 2, name: "Rent", amount: try rent()),
            .dailyLog, .weeklyReview, .test
        ]
        for message in messages {
            use(.english)
            let english = (ReminderText.title(for: message), ReminderText.body(for: message))
            use(.simplifiedChinese)
            let chinese = (ReminderText.title(for: message), ReminderText.body(for: message))
            for text in [english.0, english.1, chinese.0, chinese.1] {
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.contains("reminder."), "A missing translation shows its key: \(text)")
                XCTAssertFalse(text.contains("%"), "A placeholder was left unfilled: \(text)")
            }
            XCTAssertNotEqual(english.0, chinese.0, "\(message)")
        }
    }

    @MainActor
    func testTheOtherRemindersHaveTheirOwnWords() {
        use(.english)
        XCTAssertEqual(ReminderText.title(for: .dailyLog), "Log today's spending")
        XCTAssertEqual(ReminderText.title(for: .weeklyReview), "Time for your weekly review")
        XCTAssertEqual(ReminderText.title(for: .test), "Test reminder")
        XCTAssertEqual(ReminderText.body(for: .test), "This is how your reminders will arrive.")
    }

    @MainActor
    func testNotificationsOfAKindStackTogether() throws {
        let detail = ReminderMessage.dueDetail(.expense, leadDays: 0, name: "Rent", amount: try rent())
        XCTAssertEqual(ReminderText.thread(for: .due(.expense, leadDays: 0)), ReminderText.thread(for: detail))
        let threads = [
            ReminderText.thread(for: detail), ReminderText.thread(for: .dailyLog),
            ReminderText.thread(for: .weeklyReview), ReminderText.thread(for: .test)
        ]
        XCTAssertEqual(Set(threads).count, threads.count)
    }

    // MARK: Days of the week

    func testAWeekStartsWhereTheRegionStartsIt() {
        XCTAssertEqual(ReminderWeekdays.ordered(firstWeekday: 1), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ReminderWeekdays.ordered(firstWeekday: 2), [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(ReminderWeekdays.ordered(firstWeekday: 7), [7, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ReminderWeekdays.ordered(firstWeekday: 0), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ReminderWeekdays.ordered(firstWeekday: 9), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(Set(ReminderWeekdays.ordered()), ReminderPreferences.allWeekdays)
    }

    func testDayNamesFollowTheAppLanguage() {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")
        XCTAssertEqual(ReminderWeekdays.name(1, locale: english), "Sunday")
        XCTAssertEqual(ReminderWeekdays.name(7, locale: english), "Saturday")
        XCTAssertEqual(ReminderWeekdays.name(2, locale: chinese), "星期一")
        XCTAssertEqual(ReminderWeekdays.name(0, locale: english), "")
        XCTAssertEqual(ReminderWeekdays.name(8, locale: english), "")
    }
}
