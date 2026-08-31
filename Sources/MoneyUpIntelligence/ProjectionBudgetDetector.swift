import Foundation
import MoneyUpCore

public enum MonthEndProjectionEngine {
    public static let minimumElapsedDayCount = 7

    public static func project(
        _ input: MonthEndProjectionInput
    ) throws -> MonthEndProjection {
        guard input.elapsedDayCount >= minimumElapsedDayCount,
              input.remainingDayCount >= 0 else {
            throw IntelligenceInputError.insufficientSamples
        }
        let currency = input.committedActuals.currency
        try requireCurrency(currency, in: input.remainingSchedules)
        try requireCurrency(currency, in: input.flexibleActuals)
        let scheduleAmount = try RobustStatistics.sum(
            input.remainingSchedules.map(\.amount)
        )
        let flexibleActualAmount = try RobustStatistics.sum(
            input.flexibleActuals.map(\.amount)
        )
        let remainingRatio = try CheckedDecimal.ratio(
            Decimal(input.remainingDayCount),
            Decimal(input.elapsedDayCount)
        )
        let burnRateAmount = try CheckedDecimal.productForCurrencyRounding(
            flexibleActualAmount,
            remainingRatio,
            currency: currency
        )
        let actualPlusSchedules = try CheckedDecimal.adding(
            input.committedActuals.amount,
            scheduleAmount
        )
        let projected = try CheckedDecimal.adding(
            actualPlusSchedules,
            burnRateAmount
        )
        return MonthEndProjection(
            committedActuals: input.committedActuals,
            remainingSchedules: try Money(scheduleAmount, currency: currency),
            flexibleBurnRateProjection: try Money(
                burnRateAmount,
                currency: currency
            ),
            projectedTotal: try Money(projected, currency: currency),
            elapsedDayCount: input.elapsedDayCount,
            remainingDayCount: input.remainingDayCount,
            ruleID: "INT-PRJ-001"
        )
    }

    private static func requireCurrency(
        _ currency: CurrencyCode,
        in values: [Money]
    ) throws {
        guard values.allSatisfy({ $0.currency == currency }) else {
            throw IntelligenceInputError.currencyMismatch
        }
    }
}

public enum BudgetSuggestionEngine {
    public static let minimumCompleteMonthCount = 3
    public static let maximumTrailingMonthCount = 6

    public static func suggestions(
        from histories: [CategoryLimitHistory]
    ) throws -> [BudgetLimitSuggestion] {
        var result: [BudgetLimitSuggestion] = []
        for history in histories.sorted(by: categoryOrder) {
            let months = Array(
                history.completeMonthlySpending.suffix(maximumTrailingMonthCount)
            )
            guard months.count >= minimumCompleteMonthCount,
                  let currency = months.first?.currency,
                  months.allSatisfy({ $0.currency == currency }),
                  history.currentLimit?.currency == nil
                    || history.currentLimit?.currency == currency else {
                continue
            }
            let amounts = months.map(\.amount)
            let median = try RobustStatistics.median(amounts)
            let mad = try RobustStatistics.medianAbsoluteDeviation(
                amounts,
                median: median
            )
            let margin = try CheckedDecimal.multiplying(mad, Decimal(2))
            let rawProposal = try CheckedDecimal.adding(median, margin)
            let proposed = try Money(
                currency.rounded(rawProposal),
                currency: currency
            )
            guard history.currentLimit != proposed else { continue }
            result.append(BudgetLimitSuggestion(
                categoryID: history.categoryID,
                currentLimit: history.currentLimit,
                proposedLimit: proposed,
                median: try Money(median, currency: currency),
                medianAbsoluteDeviation: try Money(mad, currency: currency),
                sampleSize: months.count,
                ruleID: "INT-BUD-001"
            ))
        }
        return result
    }

    public static func finding(
        for suggestions: [BudgetLimitSuggestion]
    ) -> IntelligenceFinding? {
        guard !suggestions.isEmpty else { return nil }
        let ordered = suggestions.sorted {
            $0.categoryID.uuidString < $1.categoryID.uuidString
        }
        return IntelligenceFinding(
            id: "budget:\(ordered.map { $0.categoryID.uuidString.lowercased() }.joined(separator: ":"))",
            kind: .budgetSuggestion,
            headlineKey: "intelligence.budget.headline",
            explanationKey: "intelligence.budget.explanation",
            ruleID: "INT-BUD-001",
            sampleSize: ordered.reduce(0) { $0 + $1.sampleSize },
            confidence: ordered.allSatisfy({ $0.sampleSize >= 6 }) ? .high : .medium,
            figures: [
                IntelligenceFigure(
                    labelKey: "intelligence.figure.categories",
                    value: .count(ordered.count)
                )
            ],
            route: .plan(categoryIDs: ordered.map(\.categoryID))
        )
    }

    private static func categoryOrder(
        _ lhs: CategoryLimitHistory,
        _ rhs: CategoryLimitHistory
    ) -> Bool {
        lhs.categoryID.uuidString < rhs.categoryID.uuidString
    }
}
