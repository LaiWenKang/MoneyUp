import Foundation
import MoneyUpCore

public enum PayeeAffinityRanker {
    public static func suggestion(
        from candidates: [PayeeAffinityCandidate],
        currency: CurrencyCode,
        eligibleCategoryIDs: Set<UUID>
    ) -> PayeeAffinitySuggestion? {
        let eligible = candidates.filter {
            $0.currency == currency
                && $0.occurrenceCount > 0
                && $0.decayedScoreUnits >= 0
                && IntelligenceDay.isValid($0.lastOccurrenceDay)
                && eligibleCategoryIDs.contains($0.categoryID)
        }
        let total = eligible.reduce(0) { partial, item in
            let result = partial.addingReportingOverflow(item.occurrenceCount)
            return result.overflow ? Int.max : result.partialValue
        }
        guard total > 0,
              let best = eligible.sorted(by: candidateOrder).first else { return nil }
        return PayeeAffinitySuggestion(
            categoryID: best.categoryID,
            confidence: confidence(support: best.occurrenceCount, total: total),
            supportingEntryCount: best.occurrenceCount,
            eligibleEntryCount: total,
            lastOccurrenceDay: best.lastOccurrenceDay,
            decayedScoreUnits: best.decayedScoreUnits
        )
    }

    private static func candidateOrder(
        _ lhs: PayeeAffinityCandidate,
        _ rhs: PayeeAffinityCandidate
    ) -> Bool {
        if lhs.occurrenceCount != rhs.occurrenceCount {
            return lhs.occurrenceCount > rhs.occurrenceCount
        }
        if lhs.decayedScoreUnits != rhs.decayedScoreUnits {
            return lhs.decayedScoreUnits > rhs.decayedScoreUnits
        }
        if lhs.lastOccurrenceDay != rhs.lastOccurrenceDay {
            return lhs.lastOccurrenceDay > rhs.lastOccurrenceDay
        }
        return lhs.categoryID.uuidString < rhs.categoryID.uuidString
    }

    private static func confidence(
        support: Int,
        total: Int
    ) -> CaptureConfidence {
        if support >= 3, support >= roundedUpFraction(total, numerator: 3, denominator: 4) {
            return .high
        }
        if support >= 2, support >= roundedUpFraction(total, numerator: 1, denominator: 2) {
            return .medium
        }
        return .low
    }

    private static func roundedUpFraction(
        _ value: Int,
        numerator: Int,
        denominator: Int
    ) -> Int {
        let quotient = value / denominator
        let remainder = value % denominator
        return quotient * numerator
            + (remainder * numerator + denominator - 1) / denominator
    }
}
