import Foundation

/// The single inclusion contract for every financial date window.
///
/// Periods are always half-open: their start is included and their end is
/// excluded. Calendar-day helpers ask `Calendar` for the next day instead of
/// adding 86,400 seconds, so daylight-saving transitions remain correct.
public enum FinancialPeriodBoundary {
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
