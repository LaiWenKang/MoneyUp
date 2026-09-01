import Foundation
import MoneyUpCore

public enum DuplicateDetector {
    public static func findings(
        in observations: [IntelligenceObservation]
    ) -> [IntelligenceFinding] {
        let groups = Dictionary(grouping: observations, by: DuplicateKey.init)
        var findings: [IntelligenceFinding] = []
        for key in groups.keys.sorted() {
            guard let group = groups[key], group.count >= 2 else { continue }
            let ordered = group.sorted(by: observationOrder)
            for pair in zip(ordered, ordered.dropFirst()) {
                findings.append(finding(first: pair.0, second: pair.1))
            }
        }
        return findings.sorted { $0.id < $1.id }
    }

    private static func finding(
        first: IntelligenceObservation,
        second: IntelligenceObservation
    ) -> IntelligenceFinding {
        IntelligenceFinding(
            id: "duplicate:\(first.entryID.uuidString.lowercased()):\(second.entryID.uuidString.lowercased())",
            kind: .possibleDuplicate,
            headlineKey: "intelligence.duplicate.headline",
            explanationKey: "intelligence.duplicate.explanation",
            ruleID: "INT-DUP-001",
            sampleSize: 2,
            confidence: .high,
            figures: [
                IntelligenceFigure(labelKey: "intelligence.figure.amount", value: .money(first.amount)),
                IntelligenceFigure(labelKey: "intelligence.figure.day", value: .day(first.day)),
                IntelligenceFigure(labelKey: "intelligence.figure.matches", value: .count(2))
            ],
            route: .history(
                entryIDs: [first.entryID, second.entryID],
                day: first.day
            )
        )
    }
}

public enum CategoryAnomalyDetector {
    public static let minimumHistoricalSampleCount = 8
    public static let trailingWindowDayCount = 366

    public static func findings(
        in observations: [IntelligenceObservation],
        asOfDay: Int
    ) throws -> [IntelligenceFinding] {
        guard IntelligenceDay.isValid(asOfDay) else {
            throw IntelligenceInputError.invalidDay
        }
        let expenses = observations.filter { $0.kind == .expense }
        let groups = Dictionary(grouping: expenses, by: CategoryCurrencyKey.init)
        var result: [IntelligenceFinding] = []
        for key in groups.keys.sorted() {
            guard let ordered = groups[key]?.sorted(by: observationOrder),
                  let candidate = ordered.last else { continue }
            let history = try relevantHistory(
                before: candidate,
                observations: ordered.dropLast()
            )
            guard history.count >= minimumHistoricalSampleCount,
                  let finding = try finding(candidate: candidate, history: history) else {
                continue
            }
            result.append(finding)
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func relevantHistory(
        before candidate: IntelligenceObservation,
        observations: ArraySlice<IntelligenceObservation>
    ) throws -> [IntelligenceObservation] {
        var result: [IntelligenceObservation] = []
        for item in observations {
            let distance = try IntelligenceDay.distance(from: item.day, to: candidate.day)
            if (1...trailingWindowDayCount).contains(distance) { result.append(item) }
        }
        return result
    }

    private static func finding(
        candidate: IntelligenceObservation,
        history: [IntelligenceObservation]
    ) throws -> IntelligenceFinding? {
        let amounts = history.map(\.amount.amount)
        let median = try RobustStatistics.median(amounts)
        let mad = try RobustStatistics.medianAbsoluteDeviation(amounts, median: median)
        let threeMAD = try CheckedDecimal.multiplying(mad, Decimal(3))
        let halfMedian = try CheckedDecimal.dividing(median, Decimal(2))
        let minimum = RobustStatistics.minorUnit(for: candidate.amount.currency)
        let margin = max(threeMAD, max(halfMedian, minimum))
        let threshold = try CheckedDecimal.adding(median, margin)
        guard candidate.amount.amount > threshold else { return nil }
        let currency = candidate.amount.currency
        return IntelligenceFinding(
            id: "anomaly:\(candidate.entryID.uuidString.lowercased())",
            kind: .categoryAnomaly,
            headlineKey: "intelligence.anomaly.headline",
            explanationKey: "intelligence.anomaly.explanation",
            ruleID: "INT-ANO-001",
            sampleSize: history.count,
            confidence: history.count >= 12 ? .high : .medium,
            figures: [
                IntelligenceFigure(labelKey: "intelligence.figure.observed", value: .money(candidate.amount)),
                IntelligenceFigure(labelKey: "intelligence.figure.median", value: .money(try Money(median, currency: currency))),
                IntelligenceFigure(labelKey: "intelligence.figure.mad", value: .money(try Money(mad, currency: currency))),
                IntelligenceFigure(labelKey: "intelligence.figure.threshold", value: .money(try Money(threshold, currency: currency)))
            ],
            route: .history(
                entryIDs: history.map(\.entryID) + [candidate.entryID],
                day: candidate.day
            )
        )
    }
}

private struct DuplicateKey: Hashable, Comparable {
    let day: Int
    let payeeKey: String
    let kind: IntelligenceObservationKind
    let currency: CurrencyCode
    let amountText: String
    let accountID: UUID

    init(_ observation: IntelligenceObservation) {
        day = observation.day
        payeeKey = observation.payeeKey
        kind = observation.kind
        currency = observation.amount.currency
        amountText = NSDecimalNumber(decimal: observation.amount.amount).stringValue
        accountID = observation.accountID
    }

    static func < (lhs: DuplicateKey, rhs: DuplicateKey) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        [
            String(day), payeeKey, kind.rawValue, currency.value,
            amountText, accountID.uuidString
        ].joined(separator: "|")
    }
}

private struct CategoryCurrencyKey: Hashable, Comparable {
    let categoryID: UUID
    let currency: CurrencyCode

    init(_ observation: IntelligenceObservation) {
        categoryID = observation.categoryID
        currency = observation.amount.currency
    }

    static func < (lhs: CategoryCurrencyKey, rhs: CategoryCurrencyKey) -> Bool {
        (lhs.categoryID.uuidString, lhs.currency.value)
            < (rhs.categoryID.uuidString, rhs.currency.value)
    }
}

private func observationOrder(
    _ lhs: IntelligenceObservation,
    _ rhs: IntelligenceObservation
) -> Bool {
    if lhs.day != rhs.day { return lhs.day < rhs.day }
    return lhs.entryID.uuidString < rhs.entryID.uuidString
}
