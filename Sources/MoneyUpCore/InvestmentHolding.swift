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

private func checkedInvestmentProduct(
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

private func checkedInvestmentSum(
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

private func checkedInvestmentDifference(
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
    public private(set) var isArchived: Bool

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
        let activityCounts = [
            priceHistory.count,
            lots.count,
            disposals.count,
            corrections.count
        ]
        guard activityCounts.allSatisfy({
            $0 <= Self.maximumActivitiesPerCollection
        }),
        activityCounts.reduce(0, +) <= Self.maximumActivitiesPerHolding else {
            throw InvestmentHoldingError.historyMismatch
        }
        guard quantity >= .zero else {
            throw InvestmentHoldingError.quantityCannotBeNegative
        }
        guard priceAsOf?.timeIntervalSinceReferenceDate.isFinite != false,
              priceHistory.allSatisfy({
                  $0.asOf.timeIntervalSinceReferenceDate.isFinite
              }),
              lots.allSatisfy({
                  $0.acquiredAt.timeIntervalSinceReferenceDate.isFinite
              }),
              disposals.allSatisfy({
                  $0.occurredAt.timeIntervalSinceReferenceDate.isFinite
              }),
              corrections.allSatisfy({
                  $0.occurredAt.timeIntervalSinceReferenceDate.isFinite
              }) else {
            throw InvestmentHoldingError.historyMismatch
        }
        guard !isArchived || quantity == .zero else {
            throw InvestmentHoldingError.historyMismatch
        }
        if let price, price.amount < .zero {
            throw InvestmentHoldingError.priceCannotBeNegative
        }
        guard price != nil || priceAsOf == nil else {
            throw InvestmentHoldingError.historyMismatch
        }
        if let price {
            _ = try Self.positionValue(quantity: quantity, unitPrice: price)
        }

        self.id = id
        self.accountID = accountID
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.quantity = quantity
        self.price = price
        self.priceAsOf = priceAsOf
        self.positionAccountID = positionAccountID
        self.isArchived = isArchived
        var history = priceHistory
        let suppliedSequences = priceHistory.map(\.activitySequence)
            + lots.map(\.activitySequence)
            + disposals.map(\.activitySequence)
            + corrections.map(\.activitySequence)
        let implicitPriceSequence: Int64
        if suppliedSequences.isEmpty || suppliedSequences.allSatisfy({ $0 == 0 }) {
            implicitPriceSequence = 0
        } else if let maximum = suppliedSequences.max(), maximum < Int64.max {
            implicitPriceSequence = maximum + 1
        } else {
            throw InvestmentHoldingError.arithmeticOverflow
        }
        if corrections.isEmpty, let price, let priceAsOf,
           !history.contains(where: { $0.price == price && $0.asOf == priceAsOf }),
           let point = try? HoldingPricePoint(
               price: price,
               asOf: priceAsOf,
               activitySequence: implicitPriceSequence
           ) {
            history.append(point)
        }
        let normalizedActivities = try Self.normalizedActivitySequences(
            priceHistory: history,
            lots: lots,
            disposals: disposals,
            corrections: corrections
        )
        let sortedHistory = normalizedActivities.priceHistory.sorted {
            if $0.asOf == $1.asOf { return $0.activitySequence < $1.activitySequence }
            return $0.asOf < $1.asOf
        }
        let sortedLots = normalizedActivities.lots.sorted {
            if $0.acquiredAt == $1.acquiredAt {
                return $0.activitySequence < $1.activitySequence
            }
            return $0.acquiredAt < $1.acquiredAt
        }
        let sortedDisposals = normalizedActivities.disposals.sorted {
            if $0.occurredAt == $1.occurredAt {
                return $0.activitySequence < $1.activitySequence
            }
            return $0.occurredAt < $1.occurredAt
        }
        let sortedCorrections = normalizedActivities.corrections.sorted {
            $0.activitySequence < $1.activitySequence
        }

        let sourceActivityIDs = sortedHistory.map(\.id)
            + sortedLots.map(\.id)
            + sortedDisposals.map(\.id)
        guard Set(sourceActivityIDs).count == sourceActivityIDs.count,
              Set(sortedCorrections.map(\.id)).count == sortedCorrections.count,
              Set(sortedCorrections.map(\.targetActivityID)).count
                == sortedCorrections.count else {
            throw InvestmentHoldingError.duplicateIdentifier
        }
        let purchaseEntryIDs = sortedLots.compactMap(\.purchaseEntryID)
        let saleEntryIDs = sortedDisposals.map(\.saleEntryID)
        let priceEntryIDs = sortedHistory.compactMap(\.priceEntryID)
        let correctionEntryIDs = sortedCorrections.compactMap(\.correctionEntryID)
        guard Set(purchaseEntryIDs + saleEntryIDs + correctionEntryIDs).count
                == purchaseEntryIDs.count + saleEntryIDs.count + correctionEntryIDs.count,
              Set(priceEntryIDs).count == priceEntryIDs.count else {
            throw InvestmentHoldingError.duplicateLinkedEntry
        }
        var linkedActivities = Dictionary(
            uniqueKeysWithValues: sortedLots.compactMap { lot in
                lot.purchaseEntryID.map { ($0, (lot.acquiredAt, lot.activitySequence)) }
            } + sortedDisposals.map {
                ($0.saleEntryID, ($0.occurredAt, $0.activitySequence))
            }
        )
        for (correctionIndex, correction) in sortedCorrections.enumerated() {
            if correctionIndex.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
            if let entryID = correction.correctionEntryID {
                linkedActivities[entryID] = (
                    correction.occurredAt,
                    correction.activitySequence
                )
            }
        }
        for point in sortedHistory {
            guard let entryID = point.priceEntryID,
                  let linked = linkedActivities[entryID] else { continue }
            let nextSequence = linked.1.addingReportingOverflow(1)
            guard !nextSequence.overflow,
                  point.asOf == linked.0,
                  point.activitySequence == nextSequence.partialValue else {
                throw InvestmentHoldingError.historyMismatch
            }
        }

        let replacementPricePointIDs = Set(
            sortedCorrections.compactMap(\.restorationPricePointID)
        )
        guard replacementPricePointIDs.count
                == sortedCorrections.compactMap(\.restorationPricePointID).count,
              replacementPricePointIDs.isSubset(of: Set(sortedHistory.map(\.id))) else {
            throw InvestmentHoldingError.historyMismatch
        }
        var correctedActivityIDs = Set<UUID>()
        var lastCorrectionDate: Date?
        for (correctionIndex, correction) in sortedCorrections.enumerated() {
            if correctionIndex.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
            let historyBeforeCorrection = sortedHistory.filter {
                $0.activitySequence < correction.activitySequence
            }
            let lotsBeforeCorrection = sortedLots.filter {
                $0.activitySequence < correction.activitySequence
            }
            let disposalsBeforeCorrection = sortedDisposals.filter {
                $0.activitySequence < correction.activitySequence
            }
            guard let expectedTarget = Self.latestSourceTarget(
                priceHistory: historyBeforeCorrection,
                lots: lotsBeforeCorrection,
                disposals: disposalsBeforeCorrection,
                correctedActivityIDs: correctedActivityIDs,
                replacementPricePointIDs: replacementPricePointIDs
            ),
            expectedTarget.target.id == correction.targetActivityID,
            expectedTarget.target.kind == correction.kind,
            expectedTarget.target.linkedEntryID == correction.targetEntryID,
            correction.activitySequence > expectedTarget.logicalSequence,
            correction.occurredAt >= expectedTarget.target.occurredAt,
            lastCorrectionDate.map({ correction.occurredAt >= $0 }) ?? true,
            (correction.targetEntryID == nil) == (correction.correctionEntryID == nil) else {
                throw InvestmentHoldingError.historyMismatch
            }

            correctedActivityIDs.insert(correction.targetActivityID)
            let previousPoint = Self.latestActiveSourcePricePoint(
                priceHistory: historyBeforeCorrection,
                lots: lotsBeforeCorrection,
                disposals: disposalsBeforeCorrection,
                correctedActivityIDs: correctedActivityIDs,
                replacementPricePointIDs: replacementPricePointIDs
            )
            if let previousPoint {
                guard let restorationID = correction.restorationPricePointID,
                      let restoration = sortedHistory.first(where: {
                          $0.id == restorationID
                      }),
                      restoration.price == previousPoint.price,
                      restoration.asOf == correction.occurredAt,
                      restoration.priceEntryID == correction.correctionEntryID,
                      restoration.activitySequence
                        == correction.activitySequence.addingReportingOverflow(1).partialValue,
                      !correction.activitySequence.addingReportingOverflow(1).overflow else {
                    throw InvestmentHoldingError.historyMismatch
                }
            } else if correction.restorationPricePointID != nil {
                throw InvestmentHoldingError.historyMismatch
            }
            lastCorrectionDate = correction.occurredAt
        }

        let currencies = [price?.currency]
            + sortedHistory.map { Optional($0.price.currency) }
            + sortedLots.map { Optional($0.unitCost.currency) }
            + sortedDisposals.flatMap {
                [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                 Optional($0.realizedGainLoss.currency)]
            }
        guard Set(currencies.compactMap { $0 }).count <= 1 else {
            throw InvestmentHoldingError.valuationCurrencyMismatch
        }
        let effectivePrice = Self.latestEffectivePriceEvent(
            priceHistory: sortedHistory,
            lots: sortedLots,
            disposals: sortedDisposals,
            corrections: sortedCorrections
        )
        let isUnconnectedLegacyQuote = positionAccountID == nil
            && sortedHistory.isEmpty
            && sortedLots.isEmpty
            && sortedDisposals.isEmpty
            && sortedCorrections.isEmpty
            && price != nil
            && priceAsOf == nil
        if !isUnconnectedLegacyQuote {
            guard price == effectivePrice?.price,
                  priceAsOf == effectivePrice?.asOf else {
                throw InvestmentHoldingError.historyMismatch
            }
        }

        guard sortedLots.isEmpty || positionAccountID != nil,
              !(quantity > .zero && sortedLots.isEmpty && positionAccountID != nil) else {
            throw InvestmentHoldingError.historyMismatch
        }

        for lot in sortedLots {
            _ = try Self.positionValue(
                quantity: lot.originalQuantity,
                unitPrice: lot.unitCost
            )
        }

        for (disposalIndex, disposal) in sortedDisposals.enumerated() {
            if disposalIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            guard disposal.quantity > .zero,
                  disposal.costBasis.amount >= .zero,
                  disposal.proceeds.amount >= .zero,
                  disposal.costBasis.currency == disposal.proceeds.currency,
                  disposal.costBasis.currency == disposal.realizedGainLoss.currency else {
                throw InvestmentHoldingError.invalidDisposal
            }
            let expectedRealized = try checkedInvestmentDifference(
                disposal.proceeds.amount,
                disposal.costBasis.amount
            )
            guard disposal.realizedGainLoss.amount
                    == disposal.realizedGainLoss.currency.rounded(expectedRealized) else {
                throw InvestmentHoldingError.invalidDisposal
            }
        }

        // First replay every retained source event to prove the immutable FIFO
        // and cost-basis history remains internally valid, even when a later
        // correction removes an event from the current projection.
        var historicalRemaining = sortedLots.map(\.originalQuantity)
        for (disposalIndex, disposal) in sortedDisposals.enumerated() {
            if disposalIndex.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
            var remainingToConsume = disposal.quantity
            var basis = Decimal.zero
            for index in sortedLots.indices where remainingToConsume > .zero {
                if index.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
                let lotPrecedesDisposal = sortedLots[index].acquiredAt < disposal.occurredAt
                    || (sortedLots[index].acquiredAt == disposal.occurredAt
                        && sortedLots[index].activitySequence < disposal.activitySequence)
                guard lotPrecedesDisposal else { continue }
                let consumed = min(historicalRemaining[index], remainingToConsume)
                historicalRemaining[index] = try checkedInvestmentDifference(
                    historicalRemaining[index],
                    consumed
                )
                remainingToConsume = try checkedInvestmentDifference(
                    remainingToConsume,
                    consumed
                )
                basis = try checkedInvestmentSum(
                    basis,
                    checkedInvestmentProduct(consumed, sortedLots[index].unitCost.amount)
                )
            }
            guard remainingToConsume == .zero,
                  disposal.costBasis.amount
                    == disposal.costBasis.currency.rounded(basis) else {
                throw InvestmentHoldingError.historyMismatch
            }
        }

        let projectedRemaining = try Self.projectedLotRemaining(
            lots: sortedLots,
            disposals: sortedDisposals,
            correctedActivityIDs: correctedActivityIDs
        )
        guard zip(projectedRemaining, sortedLots).allSatisfy({ pair in
            pair.0 == pair.1.remainingQuantity
        }) else {
            throw InvestmentHoldingError.historyMismatch
        }
        if !sortedLots.isEmpty {
            var projectedQuantity = Decimal.zero
            for remaining in projectedRemaining {
                projectedQuantity = try checkedInvestmentSum(projectedQuantity, remaining)
            }
            guard projectedQuantity == quantity else {
                throw InvestmentHoldingError.lotQuantityMismatch
            }
        }

        self.priceHistory = sortedHistory
        self.lots = sortedLots
        self.disposals = sortedDisposals
        self.corrections = sortedCorrections
    }
}
