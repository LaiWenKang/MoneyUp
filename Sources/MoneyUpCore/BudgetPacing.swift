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

public enum BudgetPaceError: Error, Equatable, Sendable {
    case dateOutsideMonth
    case invalidCalendarRange
    case arithmeticOverflow
}

/// Deterministically apportions a remaining monthly amount over the remaining
/// reporting days. The final bucket receives any minor-unit remainder, so the
/// complete sequence always sums exactly to the supplied monthly remainder.
public enum BudgetPaceCalculator {
    public static func pace(
        remaining: Money,
        cadence: BudgetPacingCadence,
        asOf: Date,
        calendar: Calendar
    ) throws -> BudgetPace {
        guard let month = calendar.dateInterval(of: .month, for: asOf),
              FinancialPeriodBoundary.contains(asOf, in: month) else {
            throw BudgetPaceError.dateOutsideMonth
        }
        let today = calendar.startOfDay(for: asOf)
        guard let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: today),
              dayAfterToday <= month.end else {
            throw BudgetPaceError.invalidCalendarRange
        }
        let remainingDays = calendar.dateComponents(
            [.day],
            from: today,
            to: month.end
        ).day ?? 0
        guard remainingDays > 0 else { throw BudgetPaceError.invalidCalendarRange }

        let bucketEnd: Date
        let bucketDays: Int
        switch cadence {
        case .monthly:
            bucketEnd = month.end
            bucketDays = remainingDays
        case .daily:
            bucketEnd = dayAfterToday
            bucketDays = 1
        case .weekly:
            let sevenDays = calendar.date(byAdding: .day, value: 7, to: today)
            bucketEnd = min(sevenDays ?? month.end, month.end)
            bucketDays = calendar.dateComponents(
                [.day],
                from: today,
                to: bucketEnd
            ).day ?? 0
        }
        guard bucketDays > 0 else { throw BudgetPaceError.invalidCalendarRange }

        let amount: Decimal
        do {
            if bucketDays == remainingDays {
                amount = remaining.amount
            } else {
                let weighted = try CheckedDecimal.multiplying(
                    remaining.amount,
                    Decimal(bucketDays)
                )
                let raw = try CheckedDecimal.divideForCurrencyRounding(
                    weighted,
                    Decimal(remainingDays),
                    currency: remaining.currency
                )
                amount = raw
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
