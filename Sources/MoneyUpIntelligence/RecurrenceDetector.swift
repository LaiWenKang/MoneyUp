import Foundation
import MoneyUpCore

public enum RecurrenceDetector {
    public static let minimumSampleCount = 4

    public static func findings(
        in observations: [IntelligenceObservation],
        asOfDay: Int
    ) throws -> [IntelligenceFinding] {
        guard IntelligenceDay.isValid(asOfDay) else {
            throw IntelligenceInputError.invalidDay
        }
        let groups = Dictionary(grouping: eligible(observations)) {
            SeriesKey(observation: $0)
        }
        var result: [IntelligenceFinding] = []
        for key in groups.keys.sorted() {
            guard let source = groups[key],
                  let stable = stableAccountSeries(source),
                  stable.count >= minimumSampleCount,
                  let analysis = try analyze(stable) else { continue }
            result.append(contentsOf: try makeFindings(
                analysis: analysis,
                observations: stable,
                asOfDay: asOfDay
            ))
        }
        return result.sorted(by: findingOrder)
    }

    private static func eligible(
        _ observations: [IntelligenceObservation]
    ) -> [IntelligenceObservation] {
        observations.filter { $0.kind != .refund }
    }

    private static func stableAccountSeries(
        _ observations: [IntelligenceObservation]
    ) -> [IntelligenceObservation]? {
        let groups = Dictionary(grouping: observations) {
            AccountCategoryKey(accountID: $0.accountID, categoryID: $0.categoryID)
        }
        guard let best = groups.sorted(by: { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count > rhs.value.count
            }
            return lhs.key < rhs.key
        }).first else { return nil }
        guard best.value.count * 4 >= observations.count * 3 else { return nil }
        return best.value.sorted(by: observationOrder)
    }

    private static func analyze(
        _ observations: [IntelligenceObservation]
    ) throws -> SeriesAnalysis? {
        let intervals = try zip(observations, observations.dropFirst()).map { pair in
            try IntelligenceDay.distance(from: pair.0.day, to: pair.1.day)
        }
        guard intervals.allSatisfy({ $0 > 0 }) else { return nil }
        let intervalMedian = try RobustStatistics.median(intervals)
        let intervalMAD = try RobustStatistics.medianAbsoluteDeviation(
            intervals,
            median: intervalMedian
        )
        guard let cadence = cadence(
            intervalMedian: intervalMedian,
            intervalMAD: intervalMAD
        ) else { return nil }
        let amounts = observations.map(\.amount.amount)
        let priceStep = try priceStep(in: observations)
        let stableAmounts = priceStep == nil ? amounts : Array(amounts.dropLast())
        let amountMedian = try RobustStatistics.median(stableAmounts)
        let amountMAD = try RobustStatistics.medianAbsoluteDeviation(
            stableAmounts,
            median: amountMedian
        )
        let amountTolerance = try maximum(
            CheckedDecimal.multiplying(amountMedian, decimalTenths(1)),
            CheckedDecimal.multiplying(
                RobustStatistics.minorUnit(for: observations[0].amount.currency),
                Decimal(2)
            )
        )
        guard amountMAD <= amountTolerance else { return nil }
        return SeriesAnalysis(
            frequency: cadence.frequency,
            intervalMedian: intervalMedian,
            intervalMAD: intervalMAD,
            expectedAmount: priceStep?.latest ?? observations.last?.amount,
            baselineAmount: try Money(
                amountMedian,
                currency: observations[0].amount.currency
            ),
            amountMAD: try Money(
                amountMAD,
                currency: observations[0].amount.currency
            ),
            priceStep: priceStep
        )
    }

    private static func cadence(
        intervalMedian: Int,
        intervalMAD: Int
    ) -> (frequency: RecurrenceFrequency, lapseTolerance: Int)? {
        if (5...9).contains(intervalMedian), intervalMAD <= 2 {
            return (.weekly, 3)
        }
        if (27...32).contains(intervalMedian), intervalMAD <= 3 {
            return (.monthly, 7)
        }
        if (360...371).contains(intervalMedian), intervalMAD <= 7 {
            return (.yearly, 14)
        }
        return nil
    }

    private static func priceStep(
        in observations: [IntelligenceObservation]
    ) throws -> PriceStep? {
        guard observations.count >= minimumSampleCount,
              let latest = observations.last?.amount else { return nil }
        let history = observations.dropLast().map(\.amount.amount)
        let median = try RobustStatistics.median(history)
        let mad = try RobustStatistics.medianAbsoluteDeviation(history, median: median)
        let relative = try CheckedDecimal.multiplying(median, decimalTenths(1))
        let robust = try CheckedDecimal.multiplying(mad, Decimal(3))
        let tolerance = try maximum(relative, robust)
        let threshold = try CheckedDecimal.adding(median, tolerance)
        guard latest.amount > threshold else { return nil }
        return PriceStep(
            previous: try Money(median, currency: latest.currency),
            latest: latest,
            threshold: try Money(threshold, currency: latest.currency)
        )
    }

    private static func makeFindings(
        analysis: SeriesAnalysis,
        observations: [IntelligenceObservation],
        asOfDay: Int
    ) throws -> [IntelligenceFinding] {
        guard let first = observations.first,
              let last = observations.last,
              let expectedAmount = analysis.expectedAmount else { return [] }
        let expectedDay = try IntelligenceDay.adding(
            analysis.frequency,
            to: last.day
        )
        let tolerance = lapseTolerance(for: analysis.frequency)
        let lapseBoundary = try IntelligenceDay.adding(days: tolerance, to: expectedDay)
        let confidence: IntelligenceConfidence = observations.count >= 6
            && analysis.intervalMAD == 0 ? .high : .medium
        var findings: [IntelligenceFinding] = []
        if asOfDay > lapseBoundary {
            findings.append(lapsedFinding(
                first: first,
                last: last,
                expectedDay: expectedDay,
                observations: observations,
                analysis: analysis,
                confidence: confidence
            ))
        } else {
            findings.append(recurrenceFinding(
                first: first,
                last: last,
                expectedDay: expectedDay,
                expectedAmount: expectedAmount,
                observations: observations,
                analysis: analysis,
                confidence: confidence
            ))
        }
        if let step = analysis.priceStep {
            findings.append(priceFinding(
                last: last,
                observations: observations,
                step: step,
                confidence: confidence
            ))
        }
        return findings
    }

    private static func recurrenceFinding(
        first: IntelligenceObservation,
        last: IntelligenceObservation,
        expectedDay: Int,
        expectedAmount: Money,
        observations: [IntelligenceObservation],
        analysis: SeriesAnalysis,
        confidence: IntelligenceConfidence
    ) -> IntelligenceFinding {
        IntelligenceFinding(
            id: "recurrence:\(last.entryID.uuidString.lowercased())",
            kind: .recurrence,
            headlineKey: "intelligence.recurrence.headline",
            explanationKey: "intelligence.recurrence.explanation",
            ruleID: "INT-REC-001",
            sampleSize: observations.count,
            confidence: confidence,
            figures: seriesFigures(
                expectedDay: expectedDay,
                amount: expectedAmount,
                analysis: analysis
            ),
            route: .scheduleOffer(ScheduleOffer(
                payeeKey: last.payeeKey,
                kind: journalKind(for: last.kind),
                amount: expectedAmount,
                accountID: last.accountID,
                categoryID: last.categoryID,
                expectedNextDay: expectedDay,
                frequency: analysis.frequency
            ))
        )
    }

    private static func lapsedFinding(
        first: IntelligenceObservation,
        last: IntelligenceObservation,
        expectedDay: Int,
        observations: [IntelligenceObservation],
        analysis: SeriesAnalysis,
        confidence: IntelligenceConfidence
    ) -> IntelligenceFinding {
        IntelligenceFinding(
            id: "lapsed:\(last.entryID.uuidString.lowercased())",
            kind: .lapsedSubscription,
            headlineKey: "intelligence.lapsed.headline",
            explanationKey: "intelligence.lapsed.explanation",
            ruleID: "INT-REC-002",
            sampleSize: observations.count,
            confidence: confidence,
            figures: seriesFigures(
                expectedDay: expectedDay,
                amount: analysis.expectedAmount ?? last.amount,
                analysis: analysis
            ),
            route: .history(
                entryIDs: observations.map(\.entryID),
                day: first.day
            )
        )
    }

    private static func priceFinding(
        last: IntelligenceObservation,
        observations: [IntelligenceObservation],
        step: PriceStep,
        confidence: IntelligenceConfidence
    ) -> IntelligenceFinding {
        IntelligenceFinding(
            id: "price:\(last.entryID.uuidString.lowercased())",
            kind: .priceIncrease,
            headlineKey: "intelligence.price_increase.headline",
            explanationKey: "intelligence.price_increase.explanation",
            ruleID: "INT-REC-003",
            sampleSize: observations.count,
            confidence: confidence,
            figures: [
                IntelligenceFigure(labelKey: "intelligence.figure.previous", value: .money(step.previous)),
                IntelligenceFigure(labelKey: "intelligence.figure.latest", value: .money(step.latest)),
                IntelligenceFigure(labelKey: "intelligence.figure.threshold", value: .money(step.threshold))
            ],
            route: .history(entryIDs: observations.map(\.entryID), day: last.day)
        )
    }

    private static func seriesFigures(
        expectedDay: Int,
        amount: Money,
        analysis: SeriesAnalysis
    ) -> [IntelligenceFigure] {
        [
            IntelligenceFigure(labelKey: "intelligence.figure.expected_amount", value: .money(amount)),
            IntelligenceFigure(labelKey: "intelligence.figure.expected_day", value: .day(expectedDay)),
            IntelligenceFigure(labelKey: "intelligence.figure.interval_median", value: .count(analysis.intervalMedian)),
            IntelligenceFigure(labelKey: "intelligence.figure.interval_mad", value: .count(analysis.intervalMAD))
        ]
    }

    private static func lapseTolerance(for frequency: RecurrenceFrequency) -> Int {
        switch frequency {
        case .weekly: 3
        case .monthly: 7
        case .yearly: 14
        }
    }

    private static func journalKind(
        for kind: IntelligenceObservationKind
    ) -> JournalEntryKind {
        kind == .income ? .income : .expense
    }

    private static func decimalTenths(_ value: Int) throws -> Decimal {
        try CheckedDecimal.dividing(Decimal(value), Decimal(10))
    }

    private static func maximum(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        try Task.checkCancellation()
        return max(lhs, rhs)
    }

    private static func observationOrder(
        _ lhs: IntelligenceObservation,
        _ rhs: IntelligenceObservation
    ) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        return lhs.entryID.uuidString < rhs.entryID.uuidString
    }

    private static func findingOrder(
        _ lhs: IntelligenceFinding,
        _ rhs: IntelligenceFinding
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.id < rhs.id
    }
}

private struct SeriesKey: Hashable, Comparable {
    let payeeKey: String
    let currency: CurrencyCode
    let kind: IntelligenceObservationKind

    init(observation: IntelligenceObservation) {
        payeeKey = observation.payeeKey
        currency = observation.amount.currency
        kind = observation.kind
    }

    static func < (lhs: SeriesKey, rhs: SeriesKey) -> Bool {
        (lhs.payeeKey, lhs.currency.value, lhs.kind.rawValue)
            < (rhs.payeeKey, rhs.currency.value, rhs.kind.rawValue)
    }
}

private struct AccountCategoryKey: Hashable, Comparable {
    let accountID: UUID
    let categoryID: UUID

    static func < (lhs: AccountCategoryKey, rhs: AccountCategoryKey) -> Bool {
        (lhs.accountID.uuidString, lhs.categoryID.uuidString)
            < (rhs.accountID.uuidString, rhs.categoryID.uuidString)
    }
}

private struct SeriesAnalysis {
    let frequency: RecurrenceFrequency
    let intervalMedian: Int
    let intervalMAD: Int
    let expectedAmount: Money?
    let baselineAmount: Money
    let amountMAD: Money
    let priceStep: PriceStep?
}

private struct PriceStep {
    let previous: Money
    let latest: Money
    let threshold: Money
}
