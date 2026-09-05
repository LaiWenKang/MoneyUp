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
    public let amountForNextSevenDays: Money
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
        amountForNextSevenDays: Money,
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
        self.amountForNextSevenDays = amountForNextSevenDays
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
        let period: BudgetPaceReportingPeriod
        do {
            period = try BudgetPaceCalculator.reportingPeriod(
                asOf: date,
                calendar: calendar
            )
        } catch {
            return nil
        }
        let today = period.startOfToday
        var baseCommitments = Decimal.zero
        var foreignCommitments: [CurrencyCode: Decimal] = [:]
        var schedulesNeedingReview = 0

        for schedule in schedules where schedule.isActive
            && schedule.kind == .expense
            && flexibleCategoryIDs.contains(schedule.categoryAccountID) {
            if schedule.nextOccurrence < today {
                schedulesNeedingReview += 1
                try addFlexibleCommitment(
                    schedule.amount,
                    baseCurrency: flexibleBudgetRemaining.currency,
                    baseCommitments: &baseCommitments,
                    foreignCommitments: &foreignCommitments
                )
            }

            var reference = today
            var count = 0
            while count < 120,
                  let occurrence = schedule.occurrence(
                    onOrAfter: reference,
                    calendar: calendar
                  ),
                  occurrence < period.endOfMonth {
                try addFlexibleCommitment(
                    schedule.amount,
                    baseCurrency: flexibleBudgetRemaining.currency,
                    baseCommitments: &baseCommitments,
                    foreignCommitments: &foreignCommitments
                )
                count += 1
                reference = occurrence.addingTimeInterval(1)
            }
        }

        let scheduled = try Money(
            baseCommitments,
            currency: flexibleBudgetRemaining.currency
        )
        let available = try flexibleBudgetRemaining.subtracting(scheduled)
        let pace = try BudgetPaceCalculator.spread(
            remaining: available,
            asOf: date,
            calendar: calendar
        )
        let excluded = try foreignCommitments
            .sorted { $0.key < $1.key }
            .map { try Money($0.value, currency: $0.key) }

        return FlexibleTodayBreakdown(
            flexibleBudgetRemaining: flexibleBudgetRemaining,
            flexibleCommitments: scheduled,
            availableForRemainingPeriod: available,
            amountPerDay: pace.daily.available,
            amountForNextSevenDays: pace.weekly.available,
            remainingDayCount: period.remainingDayCount,
            periodStart: today,
            periodEnd: period.endOfMonth,
            excludedForeignSpending: excludedForeignSpending.sorted {
                $0.currency < $1.currency
            },
            excludedForeignCommitments: excluded,
            schedulesNeedingReview: schedulesNeedingReview
        )
    }

    private static func addFlexibleCommitment(
        _ amount: Money,
        baseCurrency: CurrencyCode,
        baseCommitments: inout Decimal,
        foreignCommitments: inout [CurrencyCode: Decimal]
    ) throws {
        if amount.currency == baseCurrency {
            baseCommitments = try CheckedDecimal.adding(
                baseCommitments,
                amount.amount
            )
        } else {
            foreignCommitments[amount.currency] = try CheckedDecimal.adding(
                foreignCommitments[amount.currency] ?? .zero,
                amount.amount
            )
        }
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
