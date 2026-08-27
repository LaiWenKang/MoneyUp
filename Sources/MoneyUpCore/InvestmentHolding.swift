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
    ) {
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
        self.init(
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
        guard quantity >= .zero else {
            throw InvestmentHoldingError.quantityCannotBeNegative
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
        for correction in sortedCorrections {
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
        for correction in sortedCorrections {
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

        for disposal in sortedDisposals {
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
        for disposal in sortedDisposals {
            var remainingToConsume = disposal.quantity
            var basis = Decimal.zero
            for index in sortedLots.indices where remainingToConsume > .zero {
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

    public func marketValue() throws -> Money? {
        guard let price else { return nil }
        return try Self.positionValue(quantity: quantity, unitPrice: price)
    }

    public static func positionValue(
        quantity: Decimal,
        unitPrice: Money
    ) throws -> Money {
        guard quantity >= .zero else {
            throw InvestmentHoldingError.quantityCannotBeNegative
        }
        guard unitPrice.amount >= .zero else {
            throw InvestmentHoldingError.priceCannotBeNegative
        }
        let product = try checkedInvestmentProduct(quantity, unitPrice.amount)
        let rounded = unitPrice.currency.rounded(product)
        guard !rounded.isNaN else {
            throw InvestmentHoldingError.arithmeticOverflow
        }
        return try Money(rounded, currency: unitPrice.currency)
    }

    public var needsLedgerConnection: Bool {
        !isArchived && positionAccountID == nil && quantity > .zero
    }

    /// Every journal identity retained by the holding metadata. A purchase or
    /// sale can intentionally also own the immediately following price point,
    /// so callers should treat this as a set rather than infer one activity per
    /// identifier.
    public var linkedEntryIDs: Set<UUID> {
        Set(lots.compactMap(\.purchaseEntryID)
            + disposals.map(\.saleEntryID)
            + priceHistory.compactMap(\.priceEntryID)
            + corrections.compactMap(\.correctionEntryID))
    }

    public var latestActivityDate: Date? {
        let dates = priceHistory.map(\.asOf)
            + lots.map(\.acquiredAt)
            + disposals.map(\.occurredAt)
            + corrections.map(\.occurredAt)
        return dates.max()
    }

    /// Only the newest uncorrected source event is exposed. Unwinding in this
    /// order is what lets a correction restore the prior FIFO projection
    /// without changing any later economic event behind the user's back.
    public var latestCorrectableActivity: InvestmentCorrectionTarget? {
        let replacementIDs = Set(corrections.compactMap(\.restorationPricePointID))
        let correctedIDs = Set(corrections.map(\.targetActivityID))
        guard let candidate = Self.latestSourceTarget(
            priceHistory: priceHistory,
            lots: lots,
            disposals: disposals,
            correctedActivityIDs: correctedIDs,
            replacementPricePointIDs: replacementIDs
        ) else { return nil }
        switch candidate.target.kind {
        case .purchase, .sale:
            guard candidate.target.linkedEntryID != nil else { return nil }
        case .valuation:
            break
        }
        return candidate.target
    }

    /// Appends an explicit correction and updates only the current projection.
    /// The caller is responsible for appending the exact compensating journal
    /// entry identified by `correctionEntryID` in the same durable transaction.
    @discardableResult
    public mutating func correctLatestActivity(
        targetActivityID: UUID,
        correctionEntryID: UUID?,
        occurredAt: Date
    ) throws -> InvestmentCorrectionOutcome {
        guard let target = latestCorrectableActivity,
              target.id == targetActivityID,
              (target.linkedEntryID == nil) == (correctionEntryID == nil),
              target.linkedEntryID == nil || target.linkedEntryID != correctionEntryID,
              correctionEntryID.map({ !linkedEntryIDs.contains($0) }) ?? true else {
            throw InvestmentHoldingError.correctionUnavailable
        }
        try requireChronologicalActivity(occurredAt)

        let correctedIDs = Set(corrections.map(\.targetActivityID))
            .union([target.id])
        let replacementIDs = Set(corrections.compactMap(\.restorationPricePointID))
        let previousPoint = Self.latestActiveSourcePricePoint(
            priceHistory: priceHistory,
            lots: lots,
            disposals: disposals,
            correctedActivityIDs: correctedIDs,
            replacementPricePointIDs: replacementIDs
        )
        let sequence = try nextActivitySequence()
        let restorationID = previousPoint.map { _ in UUID() }
        let correction = try InvestmentActivityCorrection(
            kind: target.kind,
            targetActivityID: target.id,
            targetEntryID: target.linkedEntryID,
            correctionEntryID: correctionEntryID,
            restorationPricePointID: restorationID,
            occurredAt: occurredAt,
            activitySequence: sequence
        )

        var updatedHistory = priceHistory
        if let previousPoint, let restorationID {
            let next = sequence.addingReportingOverflow(1)
            guard !next.overflow else {
                throw InvestmentHoldingError.arithmeticOverflow
            }
            updatedHistory.append(try HoldingPricePoint(
                id: restorationID,
                price: previousPoint.price,
                asOf: occurredAt,
                priceEntryID: correctionEntryID,
                activitySequence: next.partialValue
            ))
        }
        var updatedLots = lots
        let projectedRemaining = try Self.projectedLotRemaining(
            lots: updatedLots,
            disposals: disposals,
            correctedActivityIDs: correctedIDs
        )
        var updatedQuantity = Decimal.zero
        for index in updatedLots.indices {
            updatedLots[index].remainingQuantity = projectedRemaining[index]
            updatedQuantity = try checkedInvestmentSum(
                updatedQuantity,
                projectedRemaining[index]
            )
        }
        var updatedCorrections = corrections
        updatedCorrections.append(correction)
        let updatedPrice = previousPoint?.price
        let updatedPriceAsOf = previousPoint == nil ? nil : occurredAt

        self = try InvestmentHolding(
            id: id,
            accountID: accountID,
            symbol: symbol,
            name: name,
            quantity: updatedQuantity,
            price: updatedPrice,
            priceAsOf: updatedPriceAsOf,
            positionAccountID: positionAccountID,
            priceHistory: updatedHistory,
            lots: updatedLots,
            disposals: disposals,
            corrections: updatedCorrections,
            isArchived: isArchived
        )
        return InvestmentCorrectionOutcome(
            kind: target.kind,
            targetEntryID: target.linkedEntryID,
            correctionEntryID: correctionEntryID
        )
    }

    public func isPriceStale(
        relativeTo date: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let priceAsOf else { return true }
        guard let threshold = calendar.date(byAdding: .day, value: -7, to: date) else {
            return true
        }
        return priceAsOf < threshold
    }

    public mutating func recordPrice(
        _ newPrice: Money,
        asOf: Date,
        entryID: UUID? = nil
    ) throws {
        guard newPrice.amount >= .zero else {
            throw InvestmentHoldingError.priceCannotBeNegative
        }
        try requireChronologicalActivity(asOf)
        if let valuationCurrency, valuationCurrency != newPrice.currency {
            throw InvestmentHoldingError.valuationCurrencyMismatch
        }
        _ = try Self.positionValue(quantity: quantity, unitPrice: newPrice)
        let sequence = try nextActivitySequence()
        price = newPrice
        priceAsOf = asOf
        priceHistory.append(try HoldingPricePoint(
            price: newPrice,
            asOf: asOf,
            priceEntryID: entryID,
            activitySequence: sequence
        ))
        priceHistory.sort {
            if $0.asOf == $1.asOf { return $0.activitySequence < $1.activitySequence }
            return $0.asOf < $1.asOf
        }
    }

    public mutating func archive() throws {
        guard quantity == .zero else {
            throw InvestmentHoldingError.historyMismatch
        }
        isArchived = true
    }

    public mutating func recordPurchase(
        quantity purchasedQuantity: Decimal,
        unitCost: Money,
        occurredAt: Date,
        entryID: UUID
    ) throws {
        guard purchasedQuantity > .zero else {
            throw InvestmentHoldingError.lotQuantityMustBePositive
        }
        try requireChronologicalActivity(occurredAt)
        if let lotCurrency = lots.first?.unitCost.currency,
           lotCurrency != unitCost.currency {
            throw InvestmentHoldingError.lotCurrencyMismatch
        }
        if let valuationCurrency, valuationCurrency != unitCost.currency {
            throw InvestmentHoldingError.valuationCurrencyMismatch
        }
        _ = try Self.positionValue(
            quantity: purchasedQuantity,
            unitPrice: unitCost
        )
        let updatedQuantity = try checkedInvestmentSum(quantity, purchasedQuantity)
        let sequence = try nextActivitySequence()
        var updatedLots = lots
        updatedLots.append(try InvestmentLot(
            acquiredAt: occurredAt,
            originalQuantity: purchasedQuantity,
            unitCost: unitCost,
            purchaseEntryID: entryID,
            activitySequence: sequence
        ))
        updatedLots.sort {
            if $0.acquiredAt == $1.acquiredAt {
                return $0.activitySequence < $1.activitySequence
            }
            return $0.acquiredAt < $1.acquiredAt
        }
        lots = updatedLots
        quantity = updatedQuantity
    }

    /// Consumes lots in acquired-date then persisted activity order. The shared
    /// sequence keeps two same-instant sales, or a purchase after a sale at the
    /// same displayed time, deterministic across encode/decode.
    public mutating func recordSale(
        quantity soldQuantity: Decimal,
        unitPrice: Money,
        occurredAt: Date,
        entryID: UUID
    ) throws -> InvestmentSaleBreakdown {
        guard soldQuantity > .zero, soldQuantity <= quantity else {
            throw InvestmentHoldingError.insufficientQuantity
        }
        try requireChronologicalActivity(occurredAt)
        if let lotCurrency = lots.first?.unitCost.currency,
           lotCurrency != unitPrice.currency {
            throw InvestmentHoldingError.lotCurrencyMismatch
        }
        if let valuationCurrency, valuationCurrency != unitPrice.currency {
            throw InvestmentHoldingError.valuationCurrencyMismatch
        }
        let saleSequence = try nextActivitySequence()

        var eligibleQuantity = Decimal.zero
        for lot in lots where lot.acquiredAt < occurredAt
            || (lot.acquiredAt == occurredAt && lot.activitySequence < saleSequence) {
            eligibleQuantity = try checkedInvestmentSum(
                eligibleQuantity,
                lot.remainingQuantity
            )
        }
        guard soldQuantity <= eligibleQuantity else {
            throw InvestmentHoldingError.activityOutOfOrder
        }

        var remainingToConsume = soldQuantity
        var basis = Decimal.zero
        var updatedLots = lots
        for index in updatedLots.indices where remainingToConsume > .zero {
            let lotPrecedesSale = updatedLots[index].acquiredAt < occurredAt
                || (updatedLots[index].acquiredAt == occurredAt
                    && updatedLots[index].activitySequence < saleSequence)
            if !lotPrecedesSale { continue }
            let consumed = min(updatedLots[index].remainingQuantity, remainingToConsume)
            updatedLots[index].remainingQuantity = try checkedInvestmentDifference(
                updatedLots[index].remainingQuantity,
                consumed
            )
            remainingToConsume = try checkedInvestmentDifference(
                remainingToConsume,
                consumed
            )
            let consumedCost = try checkedInvestmentProduct(
                consumed,
                updatedLots[index].unitCost.amount
            )
            basis = try checkedInvestmentSum(basis, consumedCost)
        }
        // Legacy holdings can have no lots. Refuse to invent a cost basis.
        guard remainingToConsume == .zero else {
            throw InvestmentHoldingError.insufficientQuantity
        }
        let updatedQuantity = try checkedInvestmentDifference(quantity, soldQuantity)
        let roundedBasis = unitPrice.currency.rounded(basis)
        let proceedsMoney = try Self.positionValue(
            quantity: soldQuantity,
            unitPrice: unitPrice
        )
        let realized = try checkedInvestmentDifference(
            proceedsMoney.amount,
            roundedBasis
        )
        let breakdown = InvestmentSaleBreakdown(
            costBasis: try Money(roundedBasis, currency: unitPrice.currency),
            proceeds: proceedsMoney,
            realizedGainLoss: try Money(
                unitPrice.currency.rounded(realized),
                currency: unitPrice.currency
            )
        )
        var updatedDisposals = disposals
        updatedDisposals.append(InvestmentDisposal(
            occurredAt: occurredAt,
            quantity: soldQuantity,
            costBasis: breakdown.costBasis,
            proceeds: breakdown.proceeds,
            realizedGainLoss: breakdown.realizedGainLoss,
            saleEntryID: entryID,
            activitySequence: saleSequence
        ))
        updatedDisposals.sort {
            if $0.occurredAt == $1.occurredAt {
                return $0.activitySequence < $1.activitySequence
            }
            return $0.occurredAt < $1.occurredAt
        }
        lots = updatedLots
        quantity = updatedQuantity
        disposals = updatedDisposals
        return breakdown
    }

    private var valuationCurrency: CurrencyCode? {
        price?.currency
            ?? priceHistory.last?.price.currency
            ?? lots.first?.unitCost.currency
            ?? disposals.first?.proceeds.currency
    }

    private struct SourceTargetCandidate {
        let target: InvestmentCorrectionTarget
        let logicalSequence: Int64
    }

    private struct EffectivePriceEvent {
        let sequence: Int64
        let price: Money?
        let asOf: Date?
    }

    private static func latestSourceTarget(
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        correctedActivityIDs: Set<UUID>,
        replacementPricePointIDs: Set<UUID>
    ) -> SourceTargetCandidate? {
        let purchaseByEntry = Dictionary(
            uniqueKeysWithValues: lots.compactMap { lot in
                lot.purchaseEntryID.map { ($0, lot) }
            }
        )
        let disposalByEntry = Dictionary(
            uniqueKeysWithValues: disposals.map { ($0.saleEntryID, $0) }
        )
        var candidates: [SourceTargetCandidate] = []
        for lot in lots where !correctedActivityIDs.contains(lot.id) {
            let pairedSequence = lot.purchaseEntryID.flatMap { entryID in
                priceHistory.first(where: { $0.priceEntryID == entryID })?
                    .activitySequence
            }
            candidates.append(SourceTargetCandidate(
                target: InvestmentCorrectionTarget(
                    id: lot.id,
                    kind: .purchase,
                    linkedEntryID: lot.purchaseEntryID,
                    occurredAt: lot.acquiredAt
                ),
                logicalSequence: max(lot.activitySequence, pairedSequence ?? 0)
            ))
        }
        for disposal in disposals where !correctedActivityIDs.contains(disposal.id) {
            let pairedSequence = priceHistory.first(where: {
                $0.priceEntryID == disposal.saleEntryID
            })?.activitySequence
            candidates.append(SourceTargetCandidate(
                target: InvestmentCorrectionTarget(
                    id: disposal.id,
                    kind: .sale,
                    linkedEntryID: disposal.saleEntryID,
                    occurredAt: disposal.occurredAt
                ),
                logicalSequence: max(disposal.activitySequence, pairedSequence ?? 0)
            ))
        }
        for point in priceHistory {
            guard !replacementPricePointIDs.contains(point.id),
                  !correctedActivityIDs.contains(point.id) else { continue }
            if let entryID = point.priceEntryID,
               purchaseByEntry[entryID] != nil || disposalByEntry[entryID] != nil {
                continue
            }
            candidates.append(SourceTargetCandidate(
                target: InvestmentCorrectionTarget(
                    id: point.id,
                    kind: .valuation,
                    linkedEntryID: point.priceEntryID,
                    occurredAt: point.asOf
                ),
                logicalSequence: point.activitySequence
            ))
        }
        return candidates.max { $0.logicalSequence < $1.logicalSequence }
    }

    private static func latestActiveSourcePricePoint(
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        correctedActivityIDs: Set<UUID>,
        replacementPricePointIDs: Set<UUID>
    ) -> HoldingPricePoint? {
        let purchaseTargetByEntry = Dictionary(
            uniqueKeysWithValues: lots.compactMap { lot in
                lot.purchaseEntryID.map { ($0, lot.id) }
            }
        )
        let saleTargetByEntry = Dictionary(
            uniqueKeysWithValues: disposals.map { ($0.saleEntryID, $0.id) }
        )
        return priceHistory
            .filter { point in
                guard !replacementPricePointIDs.contains(point.id),
                      !correctedActivityIDs.contains(point.id) else { return false }
                guard let entryID = point.priceEntryID else { return true }
                if let targetID = purchaseTargetByEntry[entryID] {
                    return !correctedActivityIDs.contains(targetID)
                }
                if let targetID = saleTargetByEntry[entryID] {
                    return !correctedActivityIDs.contains(targetID)
                }
                return true
            }
            .max { $0.activitySequence < $1.activitySequence }
    }

    private static func latestEffectivePriceEvent(
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        corrections: [InvestmentActivityCorrection]
    ) -> EffectivePriceEvent? {
        let correctedIDs = Set(corrections.map(\.targetActivityID))
        let replacementIDs = Set(corrections.compactMap(\.restorationPricePointID))
        var events = priceHistory.filter { point in
            latestActiveSourcePricePoint(
                priceHistory: [point],
                lots: lots,
                disposals: disposals,
                correctedActivityIDs: correctedIDs,
                replacementPricePointIDs: replacementIDs
            ) != nil
        }.map {
            EffectivePriceEvent(
                sequence: $0.activitySequence,
                price: $0.price,
                asOf: $0.asOf
            )
        }
        for correction in corrections {
            if let restorationID = correction.restorationPricePointID,
               let point = priceHistory.first(where: { $0.id == restorationID }) {
                events.append(EffectivePriceEvent(
                    sequence: point.activitySequence,
                    price: point.price,
                    asOf: point.asOf
                ))
            } else {
                events.append(EffectivePriceEvent(
                    sequence: correction.activitySequence,
                    price: nil,
                    asOf: nil
                ))
            }
        }
        return events.max { $0.sequence < $1.sequence }
    }

    private static func projectedLotRemaining(
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        correctedActivityIDs: Set<UUID>
    ) throws -> [Decimal] {
        var remaining = lots.map { lot in
            correctedActivityIDs.contains(lot.id) ? Decimal.zero : lot.originalQuantity
        }
        for disposal in disposals where !correctedActivityIDs.contains(disposal.id) {
            var remainingToConsume = disposal.quantity
            for index in lots.indices where remainingToConsume > .zero {
                guard !correctedActivityIDs.contains(lots[index].id) else { continue }
                let lotPrecedesDisposal = lots[index].acquiredAt < disposal.occurredAt
                    || (lots[index].acquiredAt == disposal.occurredAt
                        && lots[index].activitySequence < disposal.activitySequence)
                guard lotPrecedesDisposal else { continue }
                let consumed = min(remaining[index], remainingToConsume)
                remaining[index] = try checkedInvestmentDifference(
                    remaining[index],
                    consumed
                )
                remainingToConsume = try checkedInvestmentDifference(
                    remainingToConsume,
                    consumed
                )
            }
            guard remainingToConsume == .zero else {
                throw InvestmentHoldingError.historyMismatch
            }
        }
        return remaining
    }

    private static func normalizedActivitySequences(
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        corrections: [InvestmentActivityCorrection]
    ) throws -> (
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        corrections: [InvestmentActivityCorrection]
    ) {
        let sequences = priceHistory.map(\.activitySequence)
            + lots.map(\.activitySequence)
            + disposals.map(\.activitySequence)
            + corrections.map(\.activitySequence)
        guard !sequences.isEmpty else {
            return (priceHistory, lots, disposals, corrections)
        }
        if sequences.allSatisfy({ $0 > 0 }) {
            guard Set(sequences).count == sequences.count else {
                throw InvestmentHoldingError.duplicateIdentifier
            }
            return (priceHistory, lots, disposals, corrections)
        }
        guard corrections.isEmpty,
              sequences.allSatisfy({ $0 == 0 }) else {
            throw InvestmentHoldingError.historyMismatch
        }

        // Legacy records had no shared sequence. Preserve array order within
        // each activity type and use purchase-before-sale-before-price for an
        // otherwise unknowable same-instant tie. Every subsequent write stores
        // an explicit sequence, so this migration happens only once.
        var slots: [(date: Date, kind: Int, index: Int)] = []
        slots += lots.indices.map { (lots[$0].acquiredAt, 0, $0) }
        slots += disposals.indices.map { (disposals[$0].occurredAt, 1, $0) }
        slots += priceHistory.indices.map { (priceHistory[$0].asOf, 2, $0) }
        slots.sort { left, right in
            if left.date != right.date { return left.date < right.date }
            if left.kind != right.kind { return left.kind < right.kind }
            return left.index < right.index
        }

        var migratedHistory = priceHistory
        var migratedLots = lots
        var migratedDisposals = disposals
        for (offset, slot) in slots.enumerated() {
            let sequence = Int64(offset + 1)
            switch slot.kind {
            case 0:
                let lot = lots[slot.index]
                migratedLots[slot.index] = try InvestmentLot(
                    id: lot.id,
                    acquiredAt: lot.acquiredAt,
                    originalQuantity: lot.originalQuantity,
                    remainingQuantity: lot.remainingQuantity,
                    unitCost: lot.unitCost,
                    purchaseEntryID: lot.purchaseEntryID,
                    activitySequence: sequence
                )
            case 1:
                let disposal = disposals[slot.index]
                migratedDisposals[slot.index] = InvestmentDisposal(
                    id: disposal.id,
                    occurredAt: disposal.occurredAt,
                    quantity: disposal.quantity,
                    costBasis: disposal.costBasis,
                    proceeds: disposal.proceeds,
                    realizedGainLoss: disposal.realizedGainLoss,
                    saleEntryID: disposal.saleEntryID,
                    activitySequence: sequence
                )
            default:
                let point = priceHistory[slot.index]
                migratedHistory[slot.index] = try HoldingPricePoint(
                    id: point.id,
                    price: point.price,
                    asOf: point.asOf,
                    priceEntryID: point.priceEntryID,
                    activitySequence: sequence
                )
            }
        }
        return (migratedHistory, migratedLots, migratedDisposals, corrections)
    }

    private func nextActivitySequence() throws -> Int64 {
        let maximum = (priceHistory.map(\.activitySequence)
            + lots.map(\.activitySequence)
            + disposals.map(\.activitySequence)
            + corrections.map(\.activitySequence)).max() ?? 0
        guard maximum < Int64.max else {
            throw InvestmentHoldingError.arithmeticOverflow
        }
        return maximum + 1
    }

    private func requireChronologicalActivity(_ date: Date) throws {
        if let latestActivityDate, date < latestActivityDate {
            throw InvestmentHoldingError.activityOutOfOrder
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case symbol
        case name
        case quantity
        case price
        case priceAsOf
        case positionAccountID
        case priceHistory
        case lots
        case disposals
        case corrections
        case isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                accountID: container.decode(UUID.self, forKey: .accountID),
                symbol: container.decode(String.self, forKey: .symbol),
                name: container.decode(String.self, forKey: .name),
                quantity: container.decode(Decimal.self, forKey: .quantity),
                price: container.decodeIfPresent(Money.self, forKey: .price),
                priceAsOf: container.decodeIfPresent(Date.self, forKey: .priceAsOf),
                positionAccountID: container.decodeIfPresent(UUID.self, forKey: .positionAccountID),
                priceHistory: try container.decodeIfPresent(
                    [HoldingPricePoint].self,
                    forKey: .priceHistory
                ) ?? [],
                lots: try container.decodeIfPresent(
                    [InvestmentLot].self,
                    forKey: .lots
                ) ?? [],
                disposals: try container.decodeIfPresent(
                    [InvestmentDisposal].self,
                    forKey: .disposals
                ) ?? [],
                corrections: try container.decodeIfPresent(
                    [InvestmentActivityCorrection].self,
                    forKey: .corrections
                ) ?? [],
                isArchived: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .isArchived
                ) ?? false
            )
        } catch let error as InvestmentHoldingError {
            throw DecodingError.dataCorruptedError(
                forKey: .quantity,
                in: container,
                debugDescription: "Invalid investment holding: \(error)"
            )
        }
    }
}
