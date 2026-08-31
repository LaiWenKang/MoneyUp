import Foundation
import MoneyUpCore

public enum IntelligenceConfidence: String, Codable, Comparable, Sendable {
    case medium
    case high

    public static func < (
        lhs: IntelligenceConfidence,
        rhs: IntelligenceConfidence
    ) -> Bool {
        lhs == .medium && rhs == .high
    }
}

public enum IntelligenceFindingKind: String, Codable, Hashable, Sendable {
    case recurrence
    case lapsedSubscription = "lapsed_subscription"
    case priceIncrease = "price_increase"
    case possibleDuplicate = "possible_duplicate"
    case categoryAnomaly = "category_anomaly"
    case budgetSuggestion = "budget_suggestion"
}

public enum IntelligenceFigureValue: Codable, Equatable, Sendable {
    case money(Money)
    case count(Int)
    case day(Int)
    case decimal(Decimal)
}

public struct IntelligenceFigure: Codable, Equatable, Sendable {
    public let labelKey: String
    public let value: IntelligenceFigureValue

    public init(labelKey: String, value: IntelligenceFigureValue) {
        self.labelKey = labelKey
        self.value = value
    }
}

public struct ScheduleOffer: Codable, Equatable, Sendable {
    public let payeeKey: String
    public let kind: JournalEntryKind
    public let amount: Money
    public let accountID: UUID
    public let categoryID: UUID
    public let expectedNextDay: Int
    public let frequency: RecurrenceFrequency

    public init(
        payeeKey: String,
        kind: JournalEntryKind,
        amount: Money,
        accountID: UUID,
        categoryID: UUID,
        expectedNextDay: Int,
        frequency: RecurrenceFrequency
    ) {
        self.payeeKey = payeeKey
        self.kind = kind
        self.amount = amount
        self.accountID = accountID
        self.categoryID = categoryID
        self.expectedNextDay = expectedNextDay
        self.frequency = frequency
    }
}

public enum IntelligenceRoute: Codable, Equatable, Sendable {
    case history(entryIDs: [UUID], day: Int?)
    case scheduleOffer(ScheduleOffer)
    case plan(categoryIDs: [UUID])
}

/// A finding contains only stable localization identifiers and exact evidence.
/// Localized prose is rendered by the app so detector bytes never depend on the
/// process locale. The rule and figures are sufficient to reproduce the result.
public struct IntelligenceFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: IntelligenceFindingKind
    public let headlineKey: String
    public let explanationKey: String
    public let ruleID: String
    public let sampleSize: Int
    public let confidence: IntelligenceConfidence
    public let figures: [IntelligenceFigure]
    public let route: IntelligenceRoute

    public init(
        id: String,
        kind: IntelligenceFindingKind,
        headlineKey: String,
        explanationKey: String,
        ruleID: String,
        sampleSize: Int,
        confidence: IntelligenceConfidence,
        figures: [IntelligenceFigure],
        route: IntelligenceRoute
    ) {
        self.id = id
        self.kind = kind
        self.headlineKey = headlineKey
        self.explanationKey = explanationKey
        self.ruleID = ruleID
        self.sampleSize = sampleSize
        self.confidence = confidence
        self.figures = figures
        self.route = route
    }
}

public enum IntelligenceObservationKind: String, Codable, Hashable, Sendable {
    case expense
    case refund
    case income
}

public struct IntelligenceObservation: Codable, Equatable, Sendable {
    public let entryID: UUID
    public let day: Int
    public let payeeKey: String
    public let kind: IntelligenceObservationKind
    public let amount: Money
    public let accountID: UUID
    public let categoryID: UUID

    public init(
        entryID: UUID,
        day: Int,
        payeeKey: String,
        kind: IntelligenceObservationKind,
        amount: Money,
        accountID: UUID,
        categoryID: UUID
    ) throws {
        guard IntelligenceDay.isValid(day),
              PayeeNormalization.isMeaningful(payeeKey),
              amount.amount > .zero else {
            throw IntelligenceInputError.invalidObservation
        }
        self.entryID = entryID
        self.day = day
        self.payeeKey = payeeKey
        self.kind = kind
        self.amount = amount
        self.accountID = accountID
        self.categoryID = categoryID
    }
}

public struct PayeeAffinityCandidate: Equatable, Sendable {
    public let categoryID: UUID
    public let currency: CurrencyCode
    public let occurrenceCount: Int
    public let lastOccurrenceDay: Int
    public let decayedScoreUnits: Int64

    public init(
        categoryID: UUID,
        currency: CurrencyCode,
        occurrenceCount: Int,
        lastOccurrenceDay: Int,
        decayedScoreUnits: Int64
    ) {
        self.categoryID = categoryID
        self.currency = currency
        self.occurrenceCount = occurrenceCount
        self.lastOccurrenceDay = lastOccurrenceDay
        self.decayedScoreUnits = decayedScoreUnits
    }
}

public struct PayeeAffinitySuggestion: Equatable, Sendable {
    public let categoryID: UUID
    public let confidence: CaptureConfidence
    public let supportingEntryCount: Int
    public let eligibleEntryCount: Int
    public let lastOccurrenceDay: Int
    public let decayedScoreUnits: Int64

    public init(
        categoryID: UUID,
        confidence: CaptureConfidence,
        supportingEntryCount: Int,
        eligibleEntryCount: Int,
        lastOccurrenceDay: Int,
        decayedScoreUnits: Int64
    ) {
        self.categoryID = categoryID
        self.confidence = confidence
        self.supportingEntryCount = supportingEntryCount
        self.eligibleEntryCount = eligibleEntryCount
        self.lastOccurrenceDay = lastOccurrenceDay
        self.decayedScoreUnits = decayedScoreUnits
    }
}

public struct CategoryLimitHistory: Equatable, Sendable {
    public let categoryID: UUID
    public let currentLimit: Money?
    public let completeMonthlySpending: [Money]

    public init(
        categoryID: UUID,
        currentLimit: Money?,
        completeMonthlySpending: [Money]
    ) {
        self.categoryID = categoryID
        self.currentLimit = currentLimit
        self.completeMonthlySpending = completeMonthlySpending
    }
}

public struct BudgetLimitSuggestion: Codable, Equatable, Sendable {
    public let categoryID: UUID
    public let currentLimit: Money?
    public let proposedLimit: Money
    public let median: Money
    public let medianAbsoluteDeviation: Money
    public let sampleSize: Int
    public let ruleID: String

    public init(
        categoryID: UUID,
        currentLimit: Money?,
        proposedLimit: Money,
        median: Money,
        medianAbsoluteDeviation: Money,
        sampleSize: Int,
        ruleID: String
    ) {
        self.categoryID = categoryID
        self.currentLimit = currentLimit
        self.proposedLimit = proposedLimit
        self.median = median
        self.medianAbsoluteDeviation = medianAbsoluteDeviation
        self.sampleSize = sampleSize
        self.ruleID = ruleID
    }
}

public struct MonthEndProjectionInput: Equatable, Sendable {
    public let committedActuals: Money
    public let remainingSchedules: [Money]
    public let flexibleActuals: [Money]
    public let elapsedDayCount: Int
    public let remainingDayCount: Int

    public init(
        committedActuals: Money,
        remainingSchedules: [Money],
        flexibleActuals: [Money],
        elapsedDayCount: Int,
        remainingDayCount: Int
    ) {
        self.committedActuals = committedActuals
        self.remainingSchedules = remainingSchedules
        self.flexibleActuals = flexibleActuals
        self.elapsedDayCount = elapsedDayCount
        self.remainingDayCount = remainingDayCount
    }
}

public struct MonthEndProjection: Codable, Equatable, Sendable {
    public let committedActuals: Money
    public let remainingSchedules: Money
    public let flexibleBurnRateProjection: Money
    public let projectedTotal: Money
    public let elapsedDayCount: Int
    public let remainingDayCount: Int
    public let ruleID: String
}

public enum IntelligenceInputError: Error, Equatable, Sendable {
    case invalidObservation
    case invalidDay
    case currencyMismatch
    case insufficientSamples
    case unavailableComponent
}
