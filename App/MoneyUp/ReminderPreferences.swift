import Foundation

/// Reminder choices for this iPhone. They are device preferences, not book
/// content: no amount, name or identifier from the book is ever stored here.
struct ReminderPreferences: Codable, Equatable, Sendable {
    static let storageKey = "moneyup.reminders"
    /// Days ahead of a due date a reminder can be asked for; 0 is the day itself.
    static let leadDayChoices = [0, 1, 2, 3, 7]
    static let maximumDailyTimes = 3
    static let defaultBillMinute = 9 * 60
    static let defaultDailyMinute = 20 * 60
    static let defaultWeeklyMinute = 19 * 60
    /// Calendar weekday numbers: 1 is Sunday.
    static let allWeekdays: Set<Int> = Set(1...7)

    var billsEnabled = false
    /// Minutes after midnight, in the book's reporting time zone.
    var billMinute = ReminderPreferences.defaultBillMinute
    var billLeadDays: Set<Int> = [0]
    var includesIncome = true
    var dailyEnabled = false
    var dailyMinutes = [ReminderPreferences.defaultDailyMinute]
    var dailyWeekdays = ReminderPreferences.allWeekdays
    /// A day that already has an entry gets no more daily nudges.
    var dailySkipsWhenLogged = true
    var weeklyEnabled = false
    var weeklyWeekday = 1
    var weeklyMinute = ReminderPreferences.defaultWeeklyMinute
    /// Names and amounts appear in notifications only when this is on.
    var showsDetails = false
    var playsSound = true
    /// Adds "in 1 hour" and "tomorrow" buttons to a reminder.
    var allowsSnooze = true

    var enabledCount: Int { [billsEnabled, dailyEnabled, weeklyEnabled].filter { $0 }.count }

    var isAnyEnabled: Bool { enabledCount > 0 }

    var style: ReminderStyle { ReminderStyle(playsSound: playsSound, allowsSnooze: allowsSnooze) }

    /// A usual moment for one more daily reminder that is not already in use.
    var suggestedExtraDailyMinute: Int {
        [12 * 60 + 30, 8 * 60, 15 * 60, 18 * 60, 21 * 60].first { !dailyMinutes.contains($0) } ?? 12 * 60
    }

    /// Ticks a lead day on or off. One always stays on: a reminder that is
    /// switched on must have a moment to fire.
    mutating func toggleLeadDay(_ day: Int) {
        Self.toggle(day, in: &billLeadDays, allowed: Self.leadDayChoices)
    }

    /// Ticks a weekday on or off; at least one stays on.
    mutating func toggleDailyWeekday(_ weekday: Int) {
        Self.toggle(weekday, in: &dailyWeekdays, allowed: Self.allWeekdays)
    }

    @discardableResult
    mutating func addDailyTime() -> Bool {
        guard dailyMinutes.count < Self.maximumDailyTimes else { return false }
        dailyMinutes.append(suggestedExtraDailyMinute)
        return true
    }

    /// The last remaining time cannot be removed; turn the reminder off instead.
    mutating func removeDailyTime(at index: Int) {
        guard dailyMinutes.count > 1, dailyMinutes.indices.contains(index) else { return }
        dailyMinutes.remove(at: index)
    }

    /// True when a kind of reminder is on now that was off in `old`: the moment
    /// to ask iOS for permission.
    func turnsOnReminders(since old: ReminderPreferences) -> Bool {
        (billsEnabled && !old.billsEnabled)
            || (dailyEnabled && !old.dailyEnabled)
            || (weeklyEnabled && !old.weeklyEnabled)
    }

    /// Daily times in the order they ring, without repeats. Applied when the
    /// screen closes, so rows never jump while a time is being turned.
    func tidied() -> ReminderPreferences {
        var value = normalized()
        value.dailyMinutes.sort()
        return value
    }

    private static func toggle(_ value: Int, in set: inout Set<Int>, allowed: some Collection<Int>) {
        guard allowed.contains(value) else { return }
        if set.contains(value) {
            if set.count > 1 { set.remove(value) }
        } else {
            set.insert(value)
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case billsEnabled, billMinute, billLeadDays, includesIncome
        case dailyEnabled, dailyMinutes, dailyWeekdays, dailySkipsWhenLogged
        case weeklyEnabled, weeklyWeekday, weeklyMinute
        case showsDetails, playsSound, allowsSnooze
    }

    /// The single daily time the first 0.7.3 builds stored.
    private enum LegacyKeys: String, CodingKey {
        case dailyMinute
    }

    /// Every key is optional so preferences saved by an earlier build, or with
    /// a value that no longer makes sense, still load instead of resetting.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        billsEnabled = try values.decodeIfPresent(Bool.self, forKey: .billsEnabled) ?? billsEnabled
        billMinute = try values.decodeIfPresent(Int.self, forKey: .billMinute) ?? billMinute
        billLeadDays = try values.decodeIfPresent(Set<Int>.self, forKey: .billLeadDays) ?? billLeadDays
        includesIncome = try values.decodeIfPresent(Bool.self, forKey: .includesIncome) ?? includesIncome
        dailyEnabled = try values.decodeIfPresent(Bool.self, forKey: .dailyEnabled) ?? dailyEnabled
        if let times = try values.decodeIfPresent([Int].self, forKey: .dailyMinutes) {
            dailyMinutes = times
        } else if let single = try legacy.decodeIfPresent(Int.self, forKey: .dailyMinute) {
            dailyMinutes = [single]
        }
        dailyWeekdays = try values.decodeIfPresent(Set<Int>.self, forKey: .dailyWeekdays) ?? dailyWeekdays
        dailySkipsWhenLogged = try values.decodeIfPresent(Bool.self, forKey: .dailySkipsWhenLogged)
            ?? dailySkipsWhenLogged
        weeklyEnabled = try values.decodeIfPresent(Bool.self, forKey: .weeklyEnabled) ?? weeklyEnabled
        weeklyWeekday = try values.decodeIfPresent(Int.self, forKey: .weeklyWeekday) ?? weeklyWeekday
        weeklyMinute = try values.decodeIfPresent(Int.self, forKey: .weeklyMinute) ?? weeklyMinute
        showsDetails = try values.decodeIfPresent(Bool.self, forKey: .showsDetails) ?? showsDetails
        playsSound = try values.decodeIfPresent(Bool.self, forKey: .playsSound) ?? playsSound
        allowsSnooze = try values.decodeIfPresent(Bool.self, forKey: .allowsSnooze) ?? allowsSnooze
        self = normalized()
    }

    /// Values a person could not have chosen fall back to the defaults.
    func normalized() -> ReminderPreferences {
        var value = self
        let minutes = 0..<(24 * 60)
        if !minutes.contains(value.billMinute) { value.billMinute = Self.defaultBillMinute }
        value.billLeadDays.formIntersection(Self.leadDayChoices)
        if value.billLeadDays.isEmpty { value.billLeadDays = [0] }
        var seen = Set<Int>()
        value.dailyMinutes = Array(
            value.dailyMinutes.filter { minutes.contains($0) && seen.insert($0).inserted }
                .prefix(Self.maximumDailyTimes)
        )
        if value.dailyMinutes.isEmpty { value.dailyMinutes = [Self.defaultDailyMinute] }
        value.dailyWeekdays.formIntersection(Self.allWeekdays)
        if value.dailyWeekdays.isEmpty { value.dailyWeekdays = Self.allWeekdays }
        if !Self.allWeekdays.contains(value.weeklyWeekday) { value.weeklyWeekday = 1 }
        if !minutes.contains(value.weeklyMinute) { value.weeklyMinute = Self.defaultWeeklyMinute }
        return value
    }

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
