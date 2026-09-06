import Foundation
import MoneyUpCore

enum GoalContributionCadence: String, CaseIterable {
    case weekly, monthly
    var component: Calendar.Component { self == .weekly ? .weekOfYear : .month }
}

enum GoalContributionProjectionError: Error {
    case invalidInput, beyondHorizon, invalidDate
}

/// A preview of equal future contributions, with no interest, returns, or
/// automatic ledger writes. Binary search compares exact products rather than
/// rounding a quotient that could underestimate the required deposit count.
struct GoalContributionProjection: Equatable {
    static let maximumPeriods = 1_200
    let periods: Int
    let completionDate: Date
    let added: Money
    let projectedBalance: Money

    static func make(
        balance: Money, target: Money, contribution: Money,
        cadence: GoalContributionCadence, asOf: Date, calendar: Calendar
    ) throws -> Self {
        guard balance.currency == target.currency, target.currency == contribution.currency,
              target.amount > .zero, contribution.amount > .zero,
              asOf.timeIntervalSinceReferenceDate.isFinite else {
            throw GoalContributionProjectionError.invalidInput
        }
        let remaining = try target.subtracting(balance)
        guard remaining.amount > .zero else {
            return Self(periods: 0, completionDate: asOf, added: .zero(currency: target.currency), projectedBalance: balance)
        }
        guard try covers(remaining.amount, contribution: contribution.amount, periods: maximumPeriods) else {
            throw GoalContributionProjectionError.beyondHorizon
        }
        var lower = 1
        var upper = maximumPeriods
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if try covers(remaining.amount, contribution: contribution.amount, periods: middle) { upper = middle }
            else { lower = middle + 1 }
        }
        guard let date = calendar.date(byAdding: cadence.component, value: lower, to: asOf),
              date.timeIntervalSinceReferenceDate.isFinite else {
            throw GoalContributionProjectionError.invalidDate
        }
        let added = try Money(CheckedDecimal.multiplying(contribution.amount, Decimal(lower)), currency: target.currency)
        return Self(periods: lower, completionDate: date, added: added, projectedBalance: try balance.adding(added))
    }

    private static func covers(_ remaining: Decimal, contribution: Decimal, periods: Int) throws -> Bool {
        do { return try CheckedDecimal.multiplying(contribution, Decimal(periods)) >= remaining }
        catch DecimalCalculationError.overflow {
            // Both operands are positive and remaining is valid finite Money;
            // an overflowing product necessarily exceeds that remaining amount.
            return true
        }
    }
}
