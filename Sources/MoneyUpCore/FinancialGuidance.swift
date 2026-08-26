import Foundation

/// The checkable arithmetic behind MoneyUp's Safe to Spend Today guidance.
///
/// The calculation never converts currencies. Active expense schedules in the
/// base currency are treated as unposted commitments; other currencies are
/// returned separately so presentation can explain the exclusion.
public struct SafeToSpendBreakdown: Equatable, Sendable {
    public let eligibleBudgetRemaining: Money
    public let scheduledCommitments: Money
    public let availableForRemainingPeriod: Money
    public let amountPerDay: Money
    public let remainingDayCount: Int
    public let periodStart: Date
    public let periodEnd: Date
    public let excludedForeignSpending: [Money]
    public let excludedForeignCommitments: [Money]
    public let schedulesNeedingReview: Int

    public init(
        eligibleBudgetRemaining: Money,
        scheduledCommitments: Money,
        availableForRemainingPeriod: Money,
        amountPerDay: Money,
        remainingDayCount: Int,
        periodStart: Date,
        periodEnd: Date,
        excludedForeignSpending: [Money],
        excludedForeignCommitments: [Money],
        schedulesNeedingReview: Int
    ) {
        self.eligibleBudgetRemaining = eligibleBudgetRemaining
        self.scheduledCommitments = scheduledCommitments
        self.availableForRemainingPeriod = availableForRemainingPeriod
        self.amountPerDay = amountPerDay
        self.remainingDayCount = remainingDayCount
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.excludedForeignSpending = excludedForeignSpending
        self.excludedForeignCommitments = excludedForeignCommitments
        self.schedulesNeedingReview = schedulesNeedingReview
    }
}

public enum FinanceScenarioError: Error, Equatable, Sendable {
    case negativeAdjustment
}

/// A read-only budget scenario. Nothing in this type mutates a ledger or
/// budget; it exists so the UI can make every projected number auditable.
public struct BudgetScenarioForecast: Equatable, Sendable {
    public let currentSpent: Money
    public let additionalSpending: Money
    public let projectedSpent: Money
    public let budgetLimit: Money
    public let projectedRemaining: Money
    public let currentIncome: Money
    public let additionalIncome: Money
    public let projectedIncome: Money
    public let projectedNet: Money

    public var budgetUsage: Decimal? {
        guard budgetLimit.amount > .zero else { return nil }
        return projectedSpent.amount / budgetLimit.amount
    }

    public init(
        currentSpent: Money,
        additionalSpending: Money,
        projectedSpent: Money,
        budgetLimit: Money,
        projectedRemaining: Money,
        currentIncome: Money,
        additionalIncome: Money,
        projectedIncome: Money,
        projectedNet: Money
    ) {
        self.currentSpent = currentSpent
        self.additionalSpending = additionalSpending
        self.projectedSpent = projectedSpent
        self.budgetLimit = budgetLimit
        self.projectedRemaining = projectedRemaining
        self.currentIncome = currentIncome
        self.additionalIncome = additionalIncome
        self.projectedIncome = projectedIncome
        self.projectedNet = projectedNet
    }
}

public extension FinanceCalculator {
    /// Calculates the daily amount available through the end of the current
    /// calendar month after active scheduled expense occurrences.
    static func safeToSpend(
        budgetRemaining: Money,
        schedules: [ScheduledTransaction],
        excludedForeignSpending: [Money] = [],
        asOf date: Date,
        calendar: Calendar = .current
    ) throws -> SafeToSpendBreakdown? {
        guard let month = calendar.dateInterval(of: .month, for: date) else {
            return nil
        }

        let today = calendar.startOfDay(for: date)
        let days = max(
            1,
            calendar.dateComponents([.day], from: today, to: month.end).day ?? 1
        )
        var baseCommitments = Decimal.zero
        var foreignCommitments: [CurrencyCode: Decimal] = [:]
        var schedulesNeedingReview = 0

        for schedule in schedules where schedule.isActive && schedule.kind == .expense {
            if schedule.nextOccurrence < today {
                schedulesNeedingReview += 1
            }

            var reference = today
            var count = 0
            while count < 120,
                  let occurrence = schedule.occurrence(
                    onOrAfter: reference,
                    calendar: calendar
                  ),
                  occurrence < month.end {
                if schedule.amount.currency == budgetRemaining.currency {
                    baseCommitments += schedule.amount.amount
                } else {
                    foreignCommitments[schedule.amount.currency, default: .zero]
                        += schedule.amount.amount
                }
                count += 1
                reference = occurrence.addingTimeInterval(1)
            }
        }

        let scheduled = try Money(
            baseCommitments,
            currency: budgetRemaining.currency
        )
        let available = try budgetRemaining.subtracting(scheduled)
        let dailyAmount = budgetRemaining.currency.rounded(
            available.amount / Decimal(days)
        )
        let perDay = try Money(
            dailyAmount,
            currency: budgetRemaining.currency
        )
        let excluded = try foreignCommitments
            .sorted { $0.key < $1.key }
            .map { try Money($0.value, currency: $0.key) }

        return SafeToSpendBreakdown(
            eligibleBudgetRemaining: budgetRemaining,
            scheduledCommitments: scheduled,
            availableForRemainingPeriod: available,
            amountPerDay: perDay,
            remainingDayCount: days,
            periodStart: today,
            periodEnd: month.end,
            excludedForeignSpending: excludedForeignSpending.sorted {
                $0.currency < $1.currency
            },
            excludedForeignCommitments: excluded,
            schedulesNeedingReview: schedulesNeedingReview
        )
    }

    static func budgetScenario(
        currentSpent: Money,
        budgetLimit: Money,
        currentIncome: Money,
        additionalSpending: Decimal,
        additionalIncome: Decimal
    ) throws -> BudgetScenarioForecast {
        guard additionalSpending >= .zero, additionalIncome >= .zero else {
            throw FinanceScenarioError.negativeAdjustment
        }

        let extraSpending = try Money(
            additionalSpending,
            currency: currentSpent.currency
        )
        let extraIncome = try Money(
            additionalIncome,
            currency: currentIncome.currency
        )
        let projectedSpent = try currentSpent.adding(extraSpending)
        let projectedIncome = try currentIncome.adding(extraIncome)
        let projectedRemaining = try budgetLimit.subtracting(projectedSpent)
        let projectedNet = try projectedIncome.subtracting(projectedSpent)

        return BudgetScenarioForecast(
            currentSpent: currentSpent,
            additionalSpending: extraSpending,
            projectedSpent: projectedSpent,
            budgetLimit: budgetLimit,
            projectedRemaining: projectedRemaining,
            currentIncome: currentIncome,
            additionalIncome: extraIncome,
            projectedIncome: projectedIncome,
            projectedNet: projectedNet
        )
    }
}
