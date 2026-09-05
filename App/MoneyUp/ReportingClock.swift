import Foundation
import SwiftUI

/// One immutable view of the book's clock and civil reporting calendar.
/// Consumers must derive a whole render's period boundaries from this value
/// instead of independently sampling the wall clock.
struct AppReportingSnapshot: Equatable, Sendable {
    let instant: Date
    let calendar: Calendar
    let reportingDayStart: Date
    let reportingDayEnd: Date

    init(instant: Date, calendar: Calendar) {
        self.instant = instant
        self.calendar = calendar
        let day = calendar.dateInterval(of: .day, for: instant)
        reportingDayStart = day?.start ?? calendar.startOfDay(for: instant)
        reportingDayEnd = day?.end
            ?? calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: instant)
            )
            ?? instant
    }

    var reportingDayIdentity: ReportingDayIdentity {
        ReportingDayIdentity(
            start: reportingDayStart,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
    }

    var monthElapsed: Double {
        guard let month = calendar.dateInterval(of: .month, for: instant) else {
            return 0
        }
        let span = month.end.timeIntervalSince(month.start)
        guard span > 0 else { return 0 }
        return min(max(instant.timeIntervalSince(month.start) / span, 0), 1)
    }
}

struct ReportingDayIdentity: Equatable, Hashable, Sendable {
    let start: Date
    let timeZoneIdentifier: String
}

/// Pure lifecycle state used by the ready hierarchy. Incrementing generation
/// cancels the prior SwiftUI task; returning active also publishes a fresh
/// snapshot synchronously, covering even a very brief suspension at midnight.
struct AppReportingClockState: Equatable, Sendable {
    private(set) var snapshot: AppReportingSnapshot
    private(set) var generation: UInt64 = 0

    init(snapshot: AppReportingSnapshot) {
        self.snapshot = snapshot
    }

    mutating func publish(instant: Date, calendar: Calendar) {
        snapshot = AppReportingSnapshot(instant: instant, calendar: calendar)
    }

    mutating func cancelForInactivity() {
        generation &+= 1
    }

    mutating func rearm(instant: Date, calendar: Calendar) {
        publish(instant: instant, calendar: calendar)
        generation &+= 1
    }
}

enum ReportingClockPolicy {
    /// Uses the book's civil reporting calendar so daylight-saving transitions
    /// never become a fixed 86,400-second approximation.
    static func nextRefresh(
        after date: Date,
        calendar: Calendar,
        scheduledOccurrences: [Date] = [],
        restrictedAllowanceChange: Date? = nil
    ) -> Date? {
        guard let dayEnd = calendar.dateInterval(of: .day, for: date)?.end else {
            return nil
        }
        let nextOccurrence = scheduledOccurrences
            .filter({ $0 >= date })
            .min()
        // Move just beyond an occurrence because `occurrence(onOrAfter:)`
        // intentionally includes an occurrence exactly equal to its argument.
        let scheduledRefresh = nextOccurrence?.addingTimeInterval(1)
        let restrictedRefresh = restrictedAllowanceChange.flatMap {
            $0 > date ? $0 : nil
        }
        return [dayEnd, scheduledRefresh, restrictedRefresh]
            .compactMap { $0 }
            .min()
    }
}

private struct AppReportingSnapshotEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppReportingSnapshot? = nil
}

extension EnvironmentValues {
    var appReportingSnapshot: AppReportingSnapshot? {
        get { self[AppReportingSnapshotEnvironmentKey.self] }
        set { self[AppReportingSnapshotEnvironmentKey.self] = newValue }
    }
}
