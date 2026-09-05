import MoneyUpCore
import SwiftUI

enum DashboardReportingContextPolicy {
    static func shouldShowReportingTimeZone(
        reportingTimeZone: TimeZone,
        deviceTimeZone: TimeZone
    ) -> Bool {
        reportingTimeZone.identifier != deviceTimeZone.identifier
    }
}

struct TodayPeriodContextPresentation: Equatable {
    let contextDescription: String
    let reportingDayDescription: String
    let monthEndDescription: String
    let inclusiveRemainingDayCount: Int
    let reportingTimeZoneDescription: String?
}

enum TodayPeriodContextFormatter {
    static func presentation(
        reportingDate: Date,
        reportingCalendar: Calendar,
        locale: Locale,
        deviceTimeZone: TimeZone,
        localizedString: (String) -> String
    ) -> TodayPeriodContextPresentation? {
        guard let period = try? BudgetPaceCalculator.reportingPeriod(
            asOf: reportingDate,
            calendar: reportingCalendar
        ), let displayedMonthEnd = reportingCalendar.date(
            byAdding: .day,
            value: -1,
            to: period.endOfMonth
        ) else { return nil }

        let day = reportingDate.formattedForReporting(
            .dateTime
                .weekday(.abbreviated)
                .month(.abbreviated)
                .day()
                .locale(locale),
            calendar: reportingCalendar
        )
        let monthEnd = displayedMonthEnd.formattedForReporting(
            .dateTime.month(.abbreviated).day().locale(locale),
            calendar: reportingCalendar
        )
        let periodDescription: String
        if period.remainingDayCount == 1 {
            periodDescription = String(
                format: localizedString(
                    "dashboard.flexible_today.context_one_day"
                ),
                locale: locale,
                arguments: [monthEnd]
            )
        } else {
            periodDescription = String(
                format: localizedString("dashboard.flexible_today.context"),
                locale: locale,
                arguments: [period.remainingDayCount, monthEnd]
            )
        }

        let reportingTimeZone = reportingCalendar.timeZone
        let reportingZoneDescription: String?
        let contextDescription: String
        if DashboardReportingContextPolicy.shouldShowReportingTimeZone(
            reportingTimeZone: reportingTimeZone,
            deviceTimeZone: deviceTimeZone
        ) {
            reportingZoneDescription = reportingTimeZone.localizedName(
                for: .shortGeneric,
                locale: locale
            ) ?? reportingTimeZone.identifier
            contextDescription = String(
                format: localizedString(
                    "dashboard.flexible_today.context_with_zone"
                ),
                locale: locale,
                arguments: [
                    day,
                    periodDescription,
                    reportingZoneDescription ?? reportingTimeZone.identifier
                ]
            )
        } else {
            reportingZoneDescription = nil
            contextDescription = String(
                format: localizedString(
                    "dashboard.flexible_today.context_without_zone"
                ),
                locale: locale,
                arguments: [day, periodDescription]
            )
        }

        return TodayPeriodContextPresentation(
            contextDescription: contextDescription,
            reportingDayDescription: day,
            monthEndDescription: monthEnd,
            inclusiveRemainingDayCount: period.remainingDayCount,
            reportingTimeZoneDescription: reportingZoneDescription
        )
    }
}

/// The title says which decision horizon Today owns; this compact line states
/// the exact civil day and denominator behind its numbers. It remains visible
/// even before a budget has been configured.
struct TodayPeriodContextView: View {
    @Environment(\.locale) private var locale
    let reportingDate: Date
    let reportingCalendar: Calendar

    var body: some View {
        if let contextDescription {
            Label(contextDescription, systemImage: "calendar")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }

    private var contextDescription: String? {
        TodayPeriodContextFormatter.presentation(
            reportingDate: reportingDate,
            reportingCalendar: reportingCalendar,
            locale: locale,
            deviceTimeZone: .autoupdatingCurrent,
            localizedString: { AppLocalization.string($0) }
        )?.contextDescription
    }
}
