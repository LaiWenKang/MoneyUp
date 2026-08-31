import Foundation
import MoneyUpCore

public enum IntelligenceDay {
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0) ?? value.timeZone
        return value
    }

    public static func isValid(_ value: Int) -> Bool {
        date(from: value) != nil
    }

    public static func distance(from start: Int, to end: Int) throws -> Int {
        guard let startDate = date(from: start), let endDate = date(from: end),
              let days = calendar.dateComponents(
                  [.day],
                  from: startDate,
                  to: endDate
              ).day else { throw IntelligenceInputError.invalidDay }
        return days
    }

    public static func adding(
        _ frequency: RecurrenceFrequency,
        to value: Int
    ) throws -> Int {
        guard let source = date(from: value) else {
            throw IntelligenceInputError.invalidDay
        }
        let component: Calendar.Component
        switch frequency {
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        }
        guard let result = calendar.date(byAdding: component, value: 1, to: source) else {
            throw IntelligenceInputError.invalidDay
        }
        return key(for: result)
    }

    public static func adding(days: Int, to value: Int) throws -> Int {
        guard let source = date(from: value),
              let result = calendar.date(byAdding: .day, value: days, to: source) else {
            throw IntelligenceInputError.invalidDay
        }
        return key(for: result)
    }

    static func components(_ value: Int) throws -> DateComponents {
        guard let date = date(from: value) else {
            throw IntelligenceInputError.invalidDay
        }
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    private static func date(from value: Int) -> Date? {
        guard value >= 10_101, value <= 99_991_231 else { return nil }
        let year = value / 10_000
        let month = (value / 100) % 100
        let day = value % 100
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else { return nil }
        return date
    }

    private static func key(for date: Date) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000
            + (parts.month ?? 0) * 100
            + (parts.day ?? 0)
    }
}
