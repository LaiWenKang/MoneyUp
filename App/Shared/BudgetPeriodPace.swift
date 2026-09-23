import SwiftUI
import WidgetKit

/// How far through the monthly budget period a moment is, derived only from
/// the period end the snapshot already carries. No new shared data is needed.
///
/// The budget period is one reporting-calendar month and its end is that
/// zone's midnight. Every real zone offset lies within UTC-12...UTC+14, so
/// thirteen hours before the end is always inside the budget month in UTC,
/// which names the month and its length without knowing the zone.
enum BudgetPeriodPace {
    static let refreshInterval: TimeInterval = 6 * 3_600
    static let maximumIntermediateEntries = 124

    static func elapsedFraction(periodEnd: Date, now: Date) -> Double? {
        var utc = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "UTC") else { return nil }
        utc.timeZone = zone
        let insideMonth = periodEnd.addingTimeInterval(-13 * 3_600)
        guard let days = utc.range(of: .day, in: .month, for: insideMonth)?.count,
              days > 0 else { return nil }
        let length = TimeInterval(days) * 86_400
        let start = periodEnd.addingTimeInterval(-length)
        guard now >= start, now < periodEnd else { return nil }
        return min(max(now.timeIntervalSince(start) / length, 0), 1)
    }

    /// Spending is "ahead of pace" only when it is clearly past the share of
    /// the month that has gone, so a normal day never reads as a warning.
    static func isAheadOfPace(percentUsed: Int, elapsed: Double) -> Bool {
        Double(percentUsed) / 100 > elapsed + 0.05
    }
}

private struct MoneyUpWidgetEntryDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// The timeline entry being drawn. Views derive time-relative marks from
    /// it instead of the render clock, which WidgetKit may run ahead of time.
    var moneyUpWidgetEntryDate: Date? {
        get { self[MoneyUpWidgetEntryDateKey.self] }
        set { self[MoneyUpWidgetEntryDateKey.self] = newValue }
    }
}

/// Budget usage with a marker for today's place in the month. Usage never
/// fills past the track, and nothing about spending more reads as progress.
struct BudgetPaceBar: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let percentUsed: Int
    let elapsed: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let used = min(max(Double(percentUsed) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(fill)
                    .frame(width: max(width * used, used > 0 ? 6 : 0))
                    .widgetAccentable()
                if let elapsed {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary)
                        .frame(width: 2, height: proxy.size.height + 6)
                        .offset(x: min(max(width * elapsed - 1, 0), width - 2))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        guard renderingMode == .fullColor else { return .primary }
        if percentUsed > 100 { return .orange }
        if let elapsed, BudgetPeriodPace.isAheadOfPace(percentUsed: percentUsed, elapsed: elapsed) {
            return Color.orange.opacity(0.85)
        }
        return .accentColor
    }
}
