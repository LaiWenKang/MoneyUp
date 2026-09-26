import Foundation

/// The month grid's shape, kept apart from rendering so it can be tested.
///
/// Cells are reporting-zone days, so their numerals come from the reporting
/// calendar: the device zone names the previous day when it lies west of the
/// reporting zone. The reporting calendar is POSIX-fixed for arithmetic, not
/// display, so the week starts where the reader's region starts it and the
/// weekday letters follow the interface language.
struct CalendarMonthLayout: Equatable {
    let cells: [Date?]
    let weekdaySymbols: [String]

    init(month: Date, calendar: Calendar, firstWeekday: Int, locale: Locale) {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let first = (1...7).contains(firstWeekday) ? firstWeekday : 1
        let leading = (calendar.component(.weekday, from: start) - first + 7) % 7
        // A day a zone skipped (Samoa, 30 December 2011) stays an empty cell,
        // so every later day keeps its weekday column and appears once.
        let yearMonth = calendar.dateComponents([.year, .month], from: start)
        let days: [Date?] = (0..<dayCount).map { offset in
            var components = yearMonth
            components.day = offset + 1
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == offset + 1 else { return nil }
            return date
        }
        var display = Calendar(identifier: .gregorian)
        display.locale = locale
        let symbols = display.veryShortStandaloneWeekdaySymbols
        cells = Array(repeating: nil, count: leading) + days
        weekdaySymbols = symbols.count == 7
            ? Array(symbols[(first - 1)...] + symbols[..<(first - 1)])
            : symbols
    }

    /// A bare numeral: a localized day such as "18日" cannot fit a day circle.
    static func dayNumeral(_ day: Date, calendar: Calendar) -> String {
        String(calendar.component(.day, from: day))
    }
}
