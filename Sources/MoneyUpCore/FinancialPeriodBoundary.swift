import Foundation

/// The single inclusion contract for every financial date window.
///
/// Periods are always half-open: their start is included and their end is
/// excluded. Calendar-day helpers ask `Calendar` for the next day instead of
/// adding 86,400 seconds, so daylight-saving transitions remain correct.
public enum FinancialPeriodBoundary {
    /// Reporting uses a fixed Gregorian calendar whose zone comes from the
    /// encrypted profile. Device travel must not redefine financial days.
    public static func gregorianCalendar(
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    public static func dayKey(
        for date: Date,
        calendar: Calendar
    ) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
    }

    /// First stable financial day whose attributed midnight is not before the
    /// requested inclusive instant bound.
    public static func lowerDayKey(
        forStartDate date: Date,
        calendar: Calendar
    ) -> Int? {
        let startOfDay = calendar.startOfDay(for: date)
        if date == startOfDay { return dayKey(for: date, calendar: calendar) }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
        else { return nil }
        return dayKey(for: nextDay, calendar: calendar)
    }

    /// First stable financial day whose attributed midnight is not before the
    /// requested exclusive instant bound.
    public static func upperDayKeyExclusive(
        forEndDateExclusive date: Date,
        calendar: Calendar
    ) -> Int? {
        let startOfDay = calendar.startOfDay(for: date)
        if date == startOfDay { return dayKey(for: date, calendar: calendar) }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
        else { return nil }
        return dayKey(for: nextDay, calendar: calendar)
    }

    /// Stable origin-day bounds for an arbitrary half-open instant interval.
    /// A non-midnight end includes its reporting day; an end exactly at the
    /// next day boundary remains exclusive.
    public static func dayKeyRange(
        for interval: DateInterval,
        calendar: Calendar
    ) -> Range<Int>? {
        guard let lower = lowerDayKey(
            forStartDate: interval.start,
            calendar: calendar
        ), let upper = upperDayKeyExclusive(
            forEndDateExclusive: interval.end,
            calendar: calendar
        ) else { return nil }
        guard lower < upper else { return nil }
        return lower..<upper
    }

    public static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }

    public static func contains(_ date: Date, in interval: DateInterval?) -> Bool {
        guard let interval else { return true }
        return contains(date, in: interval)
    }

    public static func contains(
        _ date: Date,
        start: Date?,
        endExclusive: Date?
    ) -> Bool {
        if let start, date < start { return false }
        if let endExclusive, date >= endExclusive { return false }
        return true
    }

    public static func startOfDay(
        containing date: Date,
        calendar: Calendar = .current
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func endOfDayExclusive(
        containing date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: date)
        )
    }

    public static func inclusiveDayInterval(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        let start = startOfDay(containing: startDate, calendar: calendar)
        guard let end = endOfDayExclusive(containing: endDate, calendar: calendar),
              start < end else { return nil }
        return DateInterval(start: start, end: end)
    }
}
