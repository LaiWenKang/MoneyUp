import Foundation

/// Income, expense, and net movement recorded in a single currency.
///
/// Core reports retain exact per-currency amounts. App presentation may add a
/// visibly estimated view only when the user has supplied an applicable dated
/// rate; missing pairs remain explicitly unconverted.
public struct CurrencyFlow: Equatable, Sendable, Identifiable {
    public let currency: CurrencyCode
    public let income: Money
    public let expense: Money
    public let net: Money

    public var id: String { currency.value }

    public var isEmpty: Bool { income.isZero && expense.isZero }

    public init(currency: CurrencyCode, income: Money, expense: Money, net: Money) {
        self.currency = currency
        self.income = income
        self.expense = expense
        self.net = net
    }
}

/// Spending recorded directly against one expense account, before any
/// roll-up into ancestor categories.
public struct CategorySpending: Equatable, Sendable, Identifiable {
    public let accountID: UUID
    public let name: String
    public let amount: Money

    public var id: UUID { accountID }

    public init(accountID: UUID, name: String, amount: Money) {
        self.accountID = accountID
        self.name = name
        self.amount = amount
    }
}

/// One calendar month of base-currency income and expense.
public struct MonthlyFlow: Equatable, Sendable, Identifiable {
    public let month: Date
    public let income: Money
    public let expense: Money
    public let net: Money

    public var id: Date { month }

    public init(month: Date, income: Money, expense: Money, net: Money) {
        self.month = month
        self.income = income
        self.expense = expense
        self.net = net
    }
}

/// A reporting window, always aligned to whole calendar months so that
/// comparisons between periods stay meaningful.
public enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case thisMonth
    case lastMonth
    case threeMonths
    case sixMonths
    case twelveMonths
    case yearToDate

    public var id: String { rawValue }

    public func interval(
        containing date: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        guard let thisMonth = calendar.dateInterval(of: .month, for: date) else {
            return nil
        }

        switch self {
        case .thisMonth:
            return thisMonth
        case .lastMonth:
            guard let earlier = calendar.date(
                byAdding: .month,
                value: -1,
                to: thisMonth.start
            ) else { return nil }
            return calendar.dateInterval(of: .month, for: earlier)
        case .threeMonths:
            return Self.window(monthsBack: 2, endingIn: thisMonth, calendar: calendar)
        case .sixMonths:
            return Self.window(monthsBack: 5, endingIn: thisMonth, calendar: calendar)
        case .twelveMonths:
            return Self.window(monthsBack: 11, endingIn: thisMonth, calendar: calendar)
        case .yearToDate:
            guard let yearStart = calendar.dateInterval(of: .year, for: date)?.start
            else { return nil }
            return DateInterval(
                start: min(yearStart, thisMonth.start),
                end: thisMonth.end
            )
        }
    }

    private static func window(
        monthsBack: Int,
        endingIn month: DateInterval,
        calendar: Calendar
    ) -> DateInterval? {
        guard let earlier = calendar.date(
            byAdding: .month,
            value: -monthsBack,
            to: month.start
        ),
        let start = calendar.dateInterval(of: .month, for: earlier)?.start else {
            return nil
        }
        return DateInterval(start: start, end: month.end)
    }
}

/// Equal elapsed portions of the current and prior calendar month.
///
/// When the prior month is shorter, its interval stops at that month's end.
/// This prevents a partial current month from being compared with a full prior
/// month while still handling dates such as 31 March deterministically.
public struct MonthToDateComparisonIntervals: Equatable, Sendable {
    public let current: DateInterval
    public let previous: DateInterval

    public init?(
        containing date: Date,
        calendar: Calendar = .current
    ) {
        guard let currentMonth = calendar.dateInterval(of: .month, for: date),
              date > currentMonth.start,
              let priorAnchor = calendar.date(
                  byAdding: .month,
                  value: -1,
                  to: currentMonth.start
              ),
              let priorMonth = calendar.dateInterval(
                  of: .month,
                  for: priorAnchor
              ) else { return nil }

        let elapsed = date.timeIntervalSince(currentMonth.start)
        let priorEnd = min(
            priorMonth.start.addingTimeInterval(elapsed),
            priorMonth.end
        )
        guard priorEnd > priorMonth.start else { return nil }

        current = DateInterval(start: currentMonth.start, end: date)
        previous = DateInterval(start: priorMonth.start, end: priorEnd)
    }
}

/// Everything the reporting screens need about one period, computed in a
/// single pass over the journal.
public struct PeriodReport: Equatable, Sendable {
    /// The window the headline totals and category breakdown cover.
    public let interval: DateInterval
    /// The window the month-by-month series covers. Callers normally use the
    /// selected `interval`, but may explicitly request a longer comparison.
    public let trendInterval: DateInterval
    public let baseCurrency: CurrencyCode
    public let baseFlow: CurrencyFlow
    /// Activity recorded in currencies other than the base currency, listed
    /// separately and never folded into `baseFlow`.
    public let foreignFlows: [CurrencyFlow]
    /// Base-currency spending per expense account, largest first.
    public let categorySpending: [CategorySpending]
    /// Base-currency income and expense for every month in `trendInterval`,
    /// including months with no activity.
    public let monthlyFlows: [MonthlyFlow]

    public init(
        interval: DateInterval,
        trendInterval: DateInterval,
        baseCurrency: CurrencyCode,
        baseFlow: CurrencyFlow,
        foreignFlows: [CurrencyFlow],
        categorySpending: [CategorySpending],
        monthlyFlows: [MonthlyFlow]
    ) {
        self.interval = interval
        self.trendInterval = trendInterval
        self.baseCurrency = baseCurrency
        self.baseFlow = baseFlow
        self.foreignFlows = foreignFlows
        self.categorySpending = categorySpending
        self.monthlyFlows = monthlyFlows
    }

    /// True when the period contains money the headline totals cannot include.
    public var holdsUnconvertedActivity: Bool { !foreignFlows.isEmpty }

    public var isEmpty: Bool { baseFlow.isEmpty && foreignFlows.isEmpty }

    /// Share of base-currency income that was not spent, as a fraction.
    /// `nil` when no income was recorded, because the ratio has no meaning.
    public func savingsRate() throws -> Decimal? {
        guard baseFlow.income.amount > .zero else { return nil }
        return try CheckedDecimal.ratio(
            baseFlow.net.amount,
            baseFlow.income.amount
        )
    }

    /// The largest positive spending category and its share of base-currency
    /// spending in this period.
    public func largestCategory() throws -> (
        category: CategorySpending,
        share: Decimal
    )? {
        guard baseFlow.expense.amount > .zero,
              let top = categorySpending.first,
              top.amount.amount > .zero else { return nil }
        return (
            top,
            try CheckedDecimal.ratio(
                top.amount.amount,
                baseFlow.expense.amount
            )
        )
    }

}
