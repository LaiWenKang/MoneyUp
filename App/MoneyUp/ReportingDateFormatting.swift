import Foundation

extension Date {
    /// Applies the financial reporting calendar to direct date formatting.
    /// Without this, travelling can move a displayed day or month even though
    /// the underlying report remains anchored to the user's chosen time zone.
    func formattedForReporting(
        _ format: Date.FormatStyle,
        calendar: Calendar
    ) -> String {
        var reportingFormat = format
        reportingFormat.calendar = calendar
        reportingFormat.timeZone = calendar.timeZone
        return reportingFormat.format(self)
    }
}
