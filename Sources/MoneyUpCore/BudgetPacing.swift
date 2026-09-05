import Foundation

/// Controls the short-horizon guidance shown for a monthly budget.
/// The monthly limit remains the source of truth; pacing never creates or
/// mutates ledger records.
public enum BudgetPacingCadence: String, Codable, CaseIterable, Hashable, Sendable {
    case monthly
    case daily
    case weekly
}

public struct BudgetPace: Equatable, Sendable {
    public let cadence: BudgetPacingCadence
    public let available: Money
    public let interval: DateInterval
    public let remainingDayCount: Int

    public init(
        cadence: BudgetPacingCadence,
        available: Money,
        interval: DateInterval,
        remainingDayCount: Int
    ) {
        self.cadence = cadence
        self.available = available
        self.interval = interval
        self.remainingDayCount = remainingDayCount
    }
}

/// The civil reporting days still owned by the current calendar month.
///
/// The interval is half-open (`startOfToday ..< startOfNextMonth`) while the
/// count includes today. Keeping this convention in one value prevents Today,
/// Plan, and explanatory copy from disagreeing around midnight or DST.
public struct BudgetPaceReportingPeriod: Equatable, Sendable {
    public let startOfToday: Date
    public let endOfMonth: Date
    public let remainingDayCount: Int

    public init(
        startOfToday: Date,
        endOfMonth: Date,
        remainingDayCount: Int
    ) {
        self.startOfToday = startOfToday
        self.endOfMonth = endOfMonth
        self.remainingDayCount = remainingDayCount
    }
}

public enum BudgetPaceError: Error, Equatable, Sendable {
    case dateOutsideMonth
    case invalidCalendarRange
    case unsupportedCurrencyPrecision
    case arithmeticOverflow
}

/// Deterministically apportions a remaining monthly amount over the remaining
/// reporting days. The final bucket receives any minor-unit remainder, so the
/// complete sequence always sums exactly to the supplied monthly remainder.
public enum BudgetPaceCalculator {
    /// Resolves the reporting month and its remaining civil-day count from one
    /// instant. Calendar arithmetic, rather than fixed 86,400-second steps,
    /// keeps the result correct across daylight-saving transitions.
    public static func reportingPeriod(
        asOf: Date,
        calendar: Calendar
    ) throws -> BudgetPaceReportingPeriod {
        guard let month = calendar.dateInterval(of: .month, for: asOf),
              FinancialPeriodBoundary.contains(asOf, in: month) else {
            throw BudgetPaceError.dateOutsideMonth
        }
        let today = calendar.startOfDay(for: asOf)
        let remainingDays = calendar.dateComponents(
            [.day],
            from: today,
            to: month.end
        ).day ?? 0
        guard remainingDays > 0,
              let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: today),
              dayAfterToday <= month.end else {
            throw BudgetPaceError.invalidCalendarRange
        }
        return BudgetPaceReportingPeriod(
            startOfToday: today,
            endOfMonth: month.end,
            remainingDayCount: remainingDays
        )
    }

    public static func pace(
        remaining: Money,
        cadence: BudgetPacingCadence,
        asOf: Date,
        calendar: Calendar
    ) throws -> BudgetPace {
        let period = try reportingPeriod(asOf: asOf, calendar: calendar)
        let today = period.startOfToday
        let remainingDays = period.remainingDayCount
        guard let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: today)
        else { throw BudgetPaceError.invalidCalendarRange }

        let bucketEnd: Date
        let bucketDays: Int
        switch cadence {
        case .monthly:
            bucketEnd = period.endOfMonth
            bucketDays = remainingDays
        case .daily:
            bucketEnd = dayAfterToday
            bucketDays = 1
        case .weekly:
            let sevenDays = calendar.date(byAdding: .day, value: 7, to: today)
            bucketEnd = min(sevenDays ?? period.endOfMonth, period.endOfMonth)
            bucketDays = calendar.dateComponents(
                [.day],
                from: today,
                to: bucketEnd
            ).day ?? 0
        }
        guard bucketDays > 0 else { throw BudgetPaceError.invalidCalendarRange }

        guard remaining.currency.supports(remaining.amount) else {
            throw BudgetPaceError.unsupportedCurrencyPrecision
        }

        let amount: Decimal
        do {
            if bucketDays == remainingDays {
                amount = remaining.amount
            } else {
                // Allocate the magnitude at currency precision and restore the
                // sign afterwards. Every ordinary day receives the same base;
                // the final reporting day receives the exact residual. A
                // shorter horizon therefore cannot round independently and
                // disagree with the monthly total.
                let magnitude = abs(remaining.amount)
                let baseMagnitude = try CheckedDecimal.divideForCurrencyFloor(
                    magnitude,
                    Decimal(remainingDays),
                    currency: remaining.currency
                )
                let bucketMagnitude = try CheckedDecimal.multiplying(
                    baseMagnitude,
                    Decimal(bucketDays)
                )
                amount = remaining.amount < .zero ? -bucketMagnitude : bucketMagnitude
            }
        } catch {
            throw BudgetPaceError.arithmeticOverflow
        }
        return BudgetPace(
            cadence: cadence,
            available: try Money(amount, currency: remaining.currency),
            interval: DateInterval(start: today, end: bucketEnd),
            remainingDayCount: remainingDays
        )
    }
}

/// Every cadence for one remaining balance, resolved from a single instant.
///
/// A board that shows month, week, and day side by side must not compute them
/// from three different "now" values; a reporting-day boundary crossed between
/// two of the calls would otherwise publish an inconsistent set.
public struct BudgetPaceSpread: Equatable, Sendable {
    public let monthly: BudgetPace
    public let weekly: BudgetPace
    public let daily: BudgetPace

    public init(monthly: BudgetPace, weekly: BudgetPace, daily: BudgetPace) {
        self.monthly = monthly
        self.weekly = weekly
        self.daily = daily
    }
}

extension BudgetPaceCalculator {
    /// Apportions one remaining balance across all three cadences at once.
    public static func spread(
        remaining: Money,
        asOf: Date,
        calendar: Calendar
    ) throws -> BudgetPaceSpread {
        BudgetPaceSpread(
            monthly: try pace(
                remaining: remaining,
                cadence: .monthly,
                asOf: asOf,
                calendar: calendar
            ),
            weekly: try pace(
                remaining: remaining,
                cadence: .weekly,
                asOf: asOf,
                calendar: calendar
            ),
            daily: try pace(
                remaining: remaining,
                cadence: .daily,
                asOf: asOf,
                calendar: calendar
            )
        )
    }
}
