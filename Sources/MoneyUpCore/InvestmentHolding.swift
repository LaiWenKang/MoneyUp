import Foundation

public enum InvestmentHoldingError: Error, Equatable, Sendable {
    case quantityCannotBeNegative
    case priceCannotBeNegative
    case lotQuantityMustBePositive
    case lotRemainingQuantityInvalid
    case lotCurrencyMismatch
    case lotQuantityMismatch
    case insufficientQuantity
    case activityOutOfOrder
    case arithmeticOverflow
    case duplicateIdentifier
    case duplicateLinkedEntry
    case valuationCurrencyMismatch
    case invalidDisposal
    case historyMismatch
    case correctionUnavailable
}

func checkedInvestmentProduct(
    _ left: Decimal,
    _ right: Decimal
) throws -> Decimal {
    do {
        return try CheckedDecimal.multiplying(left, right)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw InvestmentHoldingError.arithmeticOverflow
    }
}

func checkedInvestmentSum(
    _ left: Decimal,
    _ right: Decimal
) throws -> Decimal {
    do {
        return try CheckedDecimal.adding(left, right)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw InvestmentHoldingError.arithmeticOverflow
    }
}

func checkedInvestmentDifference(
    _ left: Decimal,
    _ right: Decimal
) throws -> Decimal {
    do {
        return try CheckedDecimal.subtracting(left, right)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw InvestmentHoldingError.arithmeticOverflow
    }
}

public struct HoldingPricePoint: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let price: Money
    public let asOf: Date
    /// The ledger entry that moved the hidden position account to this price.
    /// Nil is retained for legacy history and price observations whose market
    /// value did not change.
    public let priceEntryID: UUID?
    public let activitySequence: Int64

    public init(
        id: UUID = UUID(),
        price: Money,
        asOf: Date,
        priceEntryID: UUID? = nil,
        activitySequence: Int64 = 0
    ) throws {
        guard price.amount >= .zero else {
            throw InvestmentHoldingError.priceCannotBeNegative
        }
        guard asOf.timeIntervalSinceReferenceDate.isFinite else {
            throw InvestmentHoldingError.historyMismatch
        }
        guard activitySequence >= 0 else {
            throw InvestmentHoldingError.historyMismatch
        }
        self.id = id
        self.price = price
        self.asOf = asOf
        self.priceEntryID = priceEntryID
        self.activitySequence = activitySequence
    }

    private enum CodingKeys: String, CodingKey {
        case id, price, asOf, priceEntryID, activitySequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            price: container.decode(Money.self, forKey: .price),
            asOf: container.decode(Date.self, forKey: .asOf),
            priceEntryID: container.decodeIfPresent(UUID.self, forKey: .priceEntryID),
            activitySequence: container.decodeIfPresent(
                Int64.self,
                forKey: .activitySequence
            ) ?? 0
        )
    }
}

/// One acquisition lot. MoneyUp uses FIFO deterministically for sale
/// bookkeeping. This is cost tracking only and must not be presented as tax
/// advice because jurisdiction-specific tax rules may differ.
public struct InvestmentLot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let acquiredAt: Date
    public let originalQuantity: Decimal
    public var remainingQuantity: Decimal
    public let unitCost: Money
    public let purchaseEntryID: UUID?
    public let activitySequence: Int64

    public init(
        id: UUID = UUID(),
        acquiredAt: Date,
        originalQuantity: Decimal,
        remainingQuantity: Decimal? = nil,
        unitCost: Money,
        purchaseEntryID: UUID? = nil,
        activitySequence: Int64 = 0
    ) throws {
        guard originalQuantity > .zero else {
            throw InvestmentHoldingError.lotQuantityMustBePositive
        }
        guard acquiredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw InvestmentHoldingError.historyMismatch
        }
        let remaining = remainingQuantity ?? originalQuantity
        guard remaining >= .zero, remaining <= originalQuantity else {
            throw InvestmentHoldingError.lotRemainingQuantityInvalid
        }
        guard unitCost.amount >= .zero else {
            throw InvestmentHoldingError.priceCannotBeNegative
        }
        guard activitySequence >= 0 else {
            throw InvestmentHoldingError.historyMismatch
        }
        self.id = id
        self.acquiredAt = acquiredAt
        self.originalQuantity = originalQuantity
        self.remainingQuantity = remaining
        self.unitCost = unitCost
        self.purchaseEntryID = purchaseEntryID
        self.activitySequence = activitySequence
    }

    private enum CodingKeys: String, CodingKey {
        case id, acquiredAt, originalQuantity, remainingQuantity, unitCost
        case purchaseEntryID, activitySequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            acquiredAt: container.decode(Date.self, forKey: .acquiredAt),
            originalQuantity: container.decode(Decimal.self, forKey: .originalQuantity),
            remainingQuantity: container.decode(Decimal.self, forKey: .remainingQuantity),
            unitCost: container.decode(Money.self, forKey: .unitCost),
            purchaseEntryID: container.decodeIfPresent(UUID.self, forKey: .purchaseEntryID),
            activitySequence: container.decodeIfPresent(
                Int64.self,
                forKey: .activitySequence
            ) ?? 0
        )
    }
}

public struct InvestmentSaleBreakdown: Equatable, Sendable {
    public let costBasis: Money
    public let proceeds: Money
    public let realizedGainLoss: Money
}

public struct InvestmentDisposal: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let quantity: Decimal
    public let costBasis: Money
    public let proceeds: Money
    public let realizedGainLoss: Money
    public let saleEntryID: UUID
    public let activitySequence: Int64

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        quantity: Decimal,
        costBasis: Money,
        proceeds: Money,
        realizedGainLoss: Money,
        saleEntryID: UUID,
        activitySequence: Int64 = 0
    ) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite,
              quantity > .zero,
              costBasis.amount >= .zero,
              proceeds.amount >= .zero,
              costBasis.currency == proceeds.currency,
              costBasis.currency == realizedGainLoss.currency,
              activitySequence >= 0 else {
            throw InvestmentHoldingError.invalidDisposal
        }
        let expectedRealized = try checkedInvestmentDifference(
            proceeds.amount,
            costBasis.amount
        )
        guard realizedGainLoss.amount
                == realizedGainLoss.currency.rounded(expectedRealized) else {
            throw InvestmentHoldingError.invalidDisposal
        }
        self.id = id
        self.occurredAt = occurredAt
        self.quantity = quantity
        self.costBasis = costBasis
        self.proceeds = proceeds
        self.realizedGainLoss = realizedGainLoss
        self.saleEntryID = saleEntryID
        self.activitySequence = activitySequence
    }

    private enum CodingKeys: String, CodingKey {
        case id, occurredAt, quantity, costBasis, proceeds, realizedGainLoss
        case saleEntryID, activitySequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(UUID.self, forKey: .id),
            occurredAt: try container.decode(Date.self, forKey: .occurredAt),
            quantity: try container.decode(Decimal.self, forKey: .quantity),
            costBasis: try container.decode(Money.self, forKey: .costBasis),
            proceeds: try container.decode(Money.self, forKey: .proceeds),
            realizedGainLoss: try container.decode(Money.self, forKey: .realizedGainLoss),
            saleEntryID: try container.decode(UUID.self, forKey: .saleEntryID),
            activitySequence: try container.decodeIfPresent(
                Int64.self,
                forKey: .activitySequence
            ) ?? 0
        )
    }
}

public enum InvestmentCorrectionKind: String, Codable, Equatable, Sendable {
    case purchase
    case sale
    case valuation
}

/// A user-facing handle for the one investment event that can be corrected
/// without rewriting later FIFO history. The activity identity is deliberately
/// separate from its optional ledger identity because a rounded, zero-delta
/// valuation has no journal entry to reverse.
public struct InvestmentCorrectionTarget: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: InvestmentCorrectionKind
    public let linkedEntryID: UUID?
    public let occurredAt: Date

    public init(
        id: UUID,
        kind: InvestmentCorrectionKind,
        linkedEntryID: UUID?,
        occurredAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.linkedEntryID = linkedEntryID
        self.occurredAt = occurredAt
    }
}

/// Immutable evidence that a retained purchase, sale, or valuation was
/// compensated. Original lots, disposals, price observations, and journal
/// entries remain present; current state is a projection of this append-only
/// activity trail.
public struct InvestmentActivityCorrection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: InvestmentCorrectionKind
    public let targetActivityID: UUID
    public let targetEntryID: UUID?
    public let correctionEntryID: UUID?
    public let restorationPricePointID: UUID?
    public let occurredAt: Date
    public let activitySequence: Int64

    public init(
        id: UUID = UUID(),
        kind: InvestmentCorrectionKind,
        targetActivityID: UUID,
        targetEntryID: UUID?,
        correctionEntryID: UUID?,
        restorationPricePointID: UUID?,
        occurredAt: Date,
        activitySequence: Int64
    ) throws {
        guard activitySequence > 0 else {
            throw InvestmentHoldingError.historyMismatch
        }
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw InvestmentHoldingError.historyMismatch
        }
        guard targetEntryID == nil || targetEntryID != correctionEntryID else {
            throw InvestmentHoldingError.duplicateLinkedEntry
        }
        self.id = id
        self.kind = kind
        self.targetActivityID = targetActivityID
        self.targetEntryID = targetEntryID
        self.correctionEntryID = correctionEntryID
        self.restorationPricePointID = restorationPricePointID
        self.occurredAt = occurredAt
        self.activitySequence = activitySequence
    }
}

public struct InvestmentCorrectionOutcome: Equatable, Sendable {
    public let kind: InvestmentCorrectionKind
    public let targetEntryID: UUID?
    public let correctionEntryID: UUID?
}

public struct InvestmentHolding: Codable, Equatable, Identifiable, Sendable {
    public static let maximumActivitiesPerCollection = 2_048
    public static let maximumActivitiesPerHolding = 4_096
    public let id: UUID
    public var accountID: UUID
    public var symbol: String
    public var name: String
    public var quantity: Decimal
    public var price: Money?
    public var priceAsOf: Date?
    /// The hidden ledger account holding this position's current market value.
    /// Nil means a legacy beta record that still needs an explicit connection.
    public var positionAccountID: UUID?
    public var priceHistory: [HoldingPricePoint]
    public var lots: [InvestmentLot]
    public var disposals: [InvestmentDisposal]
    public private(set) var corrections: [InvestmentActivityCorrection]
    public internal(set) var isArchived: Bool

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        symbol: String,
        name: String,
        quantity: Decimal,
        price: Money? = nil,
        priceAsOf: Date? = nil,
        positionAccountID: UUID? = nil,
        priceHistory: [HoldingPricePoint] = [],
        lots: [InvestmentLot] = [],
        disposals: [InvestmentDisposal] = [],
        corrections: [InvestmentActivityCorrection] = [],
        isArchived: Bool = false
    ) throws {
        try InvestmentHoldingValidation.validateInputs(
            quantity: quantity,
            price: price,
            priceAsOf: priceAsOf,
            priceHistory: priceHistory,
            lots: lots,
            disposals: disposals,
            corrections: corrections,
            isArchived: isArchived
        )
        let activities = try InvestmentHoldingValidation.normalizedActivities(
            price: price,
            priceAsOf: priceAsOf,
            priceHistory: priceHistory,
            lots: lots,
            disposals: disposals,
            corrections: corrections
        )
        try InvestmentHoldingValidation.validateIdentifiersAndLinks(activities)
        let correctedIDs = try InvestmentHoldingValidation.validateCorrections(activities)
        try InvestmentHoldingValidation.validateValuation(
            quantity: quantity,
            price: price,
            priceAsOf: priceAsOf,
            positionAccountID: positionAccountID,
            activities: activities
        )
        try InvestmentHoldingValidation.validateLotsAndDisposals(activities)
        try InvestmentHoldingValidation.validateHistoricalFIFO(activities)
        try InvestmentHoldingValidation.validateProjection(
            quantity: quantity,
            activities: activities,
            correctedActivityIDs: correctedIDs
        )
        self.id = id
        self.accountID = accountID
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.quantity = quantity
        self.price = price
        self.priceAsOf = priceAsOf
        self.positionAccountID = positionAccountID
        self.isArchived = isArchived
        self.priceHistory = activities.priceHistory
        self.lots = activities.lots
        self.disposals = activities.disposals
        self.corrections = activities.corrections
    }
}
