import Foundation

/// The checkable arithmetic behind MoneyUp's Flexible Today guidance.
///
/// The calculation never converts currencies. Active expense schedules in the
/// explicitly flexible budget are treated as unposted commitments; reserved
/// bills, debt, and goals never become discretionary money.
public struct FlexibleTodayBreakdown: Equatable, Sendable {
    public let flexibleBudgetRemaining: Money
    public let flexibleCommitments: Money
    public let availableForRemainingPeriod: Money
    public let amountPerDay: Money
    public let remainingDayCount: Int
    public let periodStart: Date
    public let periodEnd: Date
    public let excludedForeignSpending: [Money]
    public let excludedForeignCommitments: [Money]
    public let schedulesNeedingReview: Int

    public init(
        flexibleBudgetRemaining: Money,
        flexibleCommitments: Money,
        availableForRemainingPeriod: Money,
        amountPerDay: Money,
        remainingDayCount: Int,
        periodStart: Date,
        periodEnd: Date,
        excludedForeignSpending: [Money],
        excludedForeignCommitments: [Money],
        schedulesNeedingReview: Int
    ) {
        self.flexibleBudgetRemaining = flexibleBudgetRemaining
        self.flexibleCommitments = flexibleCommitments
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

public enum FlexibleTodayStatus: Equatable, Sendable {
    case needsBudget
    case needsClassification(count: Int)
    case needsFlexibleBudget
    case available(FlexibleTodayBreakdown)
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

    public func budgetUsage() throws -> Decimal? {
        guard budgetLimit.amount > .zero else { return nil }
        return try CheckedDecimal.ratio(
            projectedSpent.amount,
            budgetLimit.amount
        )
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
    /// Calculates plan-paced flexible spending through the end of the month.
    /// Only schedules in `flexibleCategoryIDs` can reduce this amount.
    static func flexibleToday(
        flexibleBudgetRemaining: Money,
        schedules: [ScheduledTransaction],
        flexibleCategoryIDs: Set<UUID>,
        excludedForeignSpending: [Money] = [],
        asOf date: Date,
        calendar: Calendar = .current
    ) throws -> FlexibleTodayBreakdown? {
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

        for schedule in schedules where schedule.isActive
            && schedule.kind == .expense
            && flexibleCategoryIDs.contains(schedule.categoryAccountID) {
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
                if schedule.amount.currency == flexibleBudgetRemaining.currency {
                    baseCommitments = try CheckedDecimal.adding(
                        baseCommitments,
                        schedule.amount.amount
                    )
                } else {
                    let currency = schedule.amount.currency
                    foreignCommitments[currency] = try CheckedDecimal.adding(
                        foreignCommitments[currency] ?? .zero,
                        schedule.amount.amount
                    )
                }
                count += 1
                reference = occurrence.addingTimeInterval(1)
            }
        }

        let scheduled = try Money(
            baseCommitments,
            currency: flexibleBudgetRemaining.currency
        )
        let available = try flexibleBudgetRemaining.subtracting(scheduled)
        let dailyAmount = try CheckedDecimal.divideForCurrencyRounding(
            available.amount,
            Decimal(days),
            currency: flexibleBudgetRemaining.currency
        )
        let perDay = try Money(
            dailyAmount,
            currency: flexibleBudgetRemaining.currency
        )
        let excluded = try foreignCommitments
            .sorted { $0.key < $1.key }
            .map { try Money($0.value, currency: $0.key) }

        return FlexibleTodayBreakdown(
            flexibleBudgetRemaining: flexibleBudgetRemaining,
            flexibleCommitments: scheduled,
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
