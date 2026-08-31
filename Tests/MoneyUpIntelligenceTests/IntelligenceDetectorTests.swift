import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import XCTest

final class IntelligenceDetectorTests: XCTestCase {
    func testPayeeAffinityIsIndependentOfBookSize() throws {
        let currency = try CurrencyCode("SGD")
        let preferred = testUUID(1)
        let alternative = testUUID(2)
        let small = [
            affinity(preferred, currency: currency, count: 75, score: 8_000),
            affinity(alternative, currency: currency, count: 25, score: 4_000)
        ]
        let large = [
            affinity(preferred, currency: currency, count: 7_500, score: 800_000),
            affinity(alternative, currency: currency, count: 2_500, score: 400_000)
        ]
        let eligible = Set([preferred, alternative])
        let smallResult = PayeeAffinityRanker.suggestion(
            from: small,
            currency: currency,
            eligibleCategoryIDs: eligible
        )
        let largeResult = PayeeAffinityRanker.suggestion(
            from: large,
            currency: currency,
            eligibleCategoryIDs: eligible
        )
        XCTAssertEqual(smallResult?.categoryID, preferred)
        XCTAssertEqual(largeResult?.categoryID, preferred)
        XCTAssertEqual(smallResult?.confidence, .high)
        XCTAssertEqual(largeResult?.confidence, .high)
    }

    func testMonthlyRecurrenceIsDeterministicAcrossInputOrder() throws {
        let observations = try monthlySeries(amounts: [20, 20, 20, 20])
        let forward = try RecurrenceDetector.findings(
            in: observations,
            asOfDay: 20260520
        )
        let reverse = try RecurrenceDetector.findings(
            in: Array(observations.reversed()),
            asOfDay: 20260520
        )
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.map(\.kind), [.recurrence])
        guard case let .scheduleOffer(offer) = forward.first?.route else {
            return XCTFail("Expected a reviewable schedule offer")
        }
        XCTAssertEqual(offer.frequency, .monthly)
        XCTAssertEqual(offer.expectedNextDay, 20260515)
    }

    func testIrregularSpendingProducesNoCadence() throws {
        let observations = try observations(days: [20260101, 20260109, 20260214, 20260430])
        XCTAssertTrue(
            try RecurrenceDetector.findings(
                in: observations,
                asOfDay: 20260501
            ).isEmpty
        )
    }

    func testLapseAndPriceIncreaseAreFirstClassFindings() throws {
        let observations = try monthlySeries(amounts: [20, 20, 20, 30])
        let findings = try RecurrenceDetector.findings(
            in: observations,
            asOfDay: 20260701
        )
        XCTAssertEqual(
            Set(findings.map(\.kind)),
            Set([.lapsedSubscription, .priceIncrease])
        )
    }

    func testDuplicateRequiresSameAccount() throws {
        let first = try observation(id: 1, day: 20260601, account: 10)
        let second = try observation(id: 2, day: 20260601, account: 11)
        XCTAssertTrue(DuplicateDetector.findings(in: [first, second]).isEmpty)
        let exact = try observation(id: 3, day: 20260601, account: 10)
        XCTAssertEqual(
            DuplicateDetector.findings(in: [first, exact]).map(\.kind),
            [.possibleDuplicate]
        )
    }

    func testSingleLargePurchaseProducesNoAnomaly() throws {
        let purchase = try observation(id: 1, day: 20260601, amount: 10_000)
        let result = try CategoryAnomalyDetector.findings(
            in: [purchase],
            asOfDay: 20260601
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testAnomalyShowsMedianMADAndThreshold() throws {
        var history: [IntelligenceObservation] = []
        for index in 0..<8 {
            history.append(try observation(
                id: index + 1,
                day: 20260101 + index,
                amount: 10
            ))
        }
        history.append(try observation(id: 20, day: 20260201, amount: 100))
        let findings = try CategoryAnomalyDetector.findings(
            in: history,
            asOfDay: 20260201
        )
        XCTAssertEqual(findings.map(\.kind), [.categoryAnomaly])
        XCTAssertEqual(findings.first?.sampleSize, 8)
        XCTAssertEqual(findings.first?.figures.count, 4)
    }

    func testProjectionRejectsMixedCurrenciesAndUsesExactComponents() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let valid = MonthEndProjectionInput(
            committedActuals: try Money(100, currency: sgd),
            remainingSchedules: [try Money(20, currency: sgd)],
            flexibleActuals: [try Money(70, currency: sgd)],
            elapsedDayCount: 7,
            remainingDayCount: 7
        )
        let projection = try MonthEndProjectionEngine.project(valid)
        XCTAssertEqual(projection.remainingSchedules.amount, 20)
        XCTAssertEqual(projection.flexibleBurnRateProjection.amount, 70)
        XCTAssertEqual(projection.projectedTotal.amount, 190)
        let invalid = MonthEndProjectionInput(
            committedActuals: valid.committedActuals,
            remainingSchedules: [try Money(20, currency: usd)],
            flexibleActuals: valid.flexibleActuals,
            elapsedDayCount: 7,
            remainingDayCount: 7
        )
        XCTAssertThrowsError(try MonthEndProjectionEngine.project(invalid))
    }

    func testBudgetSuggestionIsMedianPlusTwoMADAndReviewOnly() throws {
        let currency = try CurrencyCode("SGD")
        let values = try [80, 90, 100, 110, 120].map {
            try Money(Decimal($0), currency: currency)
        }
        let suggestions = try BudgetSuggestionEngine.suggestions(from: [
            CategoryLimitHistory(
                categoryID: testUUID(30),
                currentLimit: try Money(90, currency: currency),
                completeMonthlySpending: values
            )
        ])
        XCTAssertEqual(suggestions.first?.median.amount, 100)
        XCTAssertEqual(suggestions.first?.medianAbsoluteDeviation.amount, 10)
        XCTAssertEqual(suggestions.first?.proposedLimit.amount, 120)
        guard let route = BudgetSuggestionEngine.finding(for: suggestions)?.route,
              case .plan = route else {
            return XCTFail("Expected a review-only Plan route")
        }
    }

    func testFindingsEncodeByteIdenticallyForEquivalentBooks() throws {
        let source = try monthlySeries(amounts: [20, 20, 20, 20])
        let first = try RecurrenceDetector.findings(in: source, asOfDay: 20260520)
        var generator = DeterministicGenerator()
        let shuffled = source.shuffled(using: &generator)
        let second = try RecurrenceDetector.findings(in: shuffled, asOfDay: 20260520)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
    }
}

private extension IntelligenceDetectorTests {
    func affinity(
        _ categoryID: UUID,
        currency: CurrencyCode,
        count: Int,
        score: Int64
    ) -> PayeeAffinityCandidate {
        PayeeAffinityCandidate(
            categoryID: categoryID,
            currency: currency,
            occurrenceCount: count,
            lastOccurrenceDay: 20260601,
            decayedScoreUnits: score
        )
    }

    func monthlySeries(amounts: [Int]) throws -> [IntelligenceObservation] {
        try zip([20260115, 20260215, 20260315, 20260415], amounts).enumerated().map {
            try observation(
                id: $0.offset + 1,
                day: $0.element.0,
                amount: $0.element.1
            )
        }
    }

    func observations(days: [Int]) throws -> [IntelligenceObservation] {
        try days.enumerated().map {
            try observation(id: $0.offset + 1, day: $0.element)
        }
    }

    func observation(
        id: Int,
        day: Int,
        amount: Int = 20,
        account: Int = 10
    ) throws -> IntelligenceObservation {
        try IntelligenceObservation(
            entryID: testUUID(id),
            day: day,
            payeeKey: "fixture merchant",
            kind: .expense,
            amount: Money(Decimal(amount), currency: CurrencyCode("SGD")),
            accountID: testUUID(account),
            categoryID: testUUID(20)
        )
    }
}

private struct DeterministicGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> UInt64 {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return state
    }
}

private func testUUID(_ value: Int) -> UUID {
    let suffix = String(format: "%012d", value)
    guard let result = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else {
        preconditionFailure("Invalid deterministic test UUID")
    }
    return result
}
