import Foundation

extension Date {
    func reportingMonthMidpoint(calendar: Calendar) -> Date {
        guard let interval = calendar.dateInterval(of: .month, for: self) else { return self }
        return interval.start.addingTimeInterval(interval.duration / 2)
    }

    /// Applies the financial reporting calendar to direct date formatting.
    /// Without this, travelling can move a displayed day or month even though
    /// the underlying report remains anchored to the user's chosen time zone.
    ///
    /// Programmatic strings do not inherit SwiftUI's locale environment, so
    /// the in-app language is applied here; otherwise a Chinese interface on
    /// an English device shows "Sep 18 at 11:00 AM" beside Chinese labels.
    /// `locale` replaces any locale set on `format`: pass it here instead.
    func formattedForReporting(
        _ format: Date.FormatStyle,
        calendar: Calendar,
        locale: Locale = AppLanguagePreference.current.locale
    ) -> String {
        var reportingFormat = format
        reportingFormat.calendar = calendar
        reportingFormat.timeZone = calendar.timeZone
        reportingFormat.locale = locale
        return reportingFormat.format(self)
    }
}
