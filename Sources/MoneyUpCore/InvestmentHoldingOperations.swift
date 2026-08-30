import Foundation

extension InvestmentHolding {
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
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let priceAsOf,
              priceAsOf.timeIntervalSinceReferenceDate.isFinite else {
            return true
        }
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
        updatedDisposals.append(try InvestmentDisposal(
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
}
