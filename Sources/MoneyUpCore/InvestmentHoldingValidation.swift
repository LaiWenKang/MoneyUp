import Foundation

struct ValidatedInvestmentActivities {
    let priceHistory: [HoldingPricePoint]
    let lots: [InvestmentLot]
    let disposals: [InvestmentDisposal]
    let corrections: [InvestmentActivityCorrection]
}

enum InvestmentHoldingValidation {
    static func validateInputs(
        quantity: Decimal,
        price: Money?,
        priceAsOf: Date?,
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        corrections: [InvestmentActivityCorrection],
        isArchived: Bool
    ) throws {
        let counts = [priceHistory.count, lots.count, disposals.count, corrections.count]
        guard counts.allSatisfy({
            $0 <= InvestmentHolding.maximumActivitiesPerCollection
        }), counts.reduce(0, +) <= InvestmentHolding.maximumActivitiesPerHolding else {
            throw InvestmentHoldingError.historyMismatch
        }
        guard quantity >= .zero else {
            throw InvestmentHoldingError.quantityCannotBeNegative
        }
        guard priceAsOf?.timeIntervalSinceReferenceDate.isFinite != false,
              priceHistory.allSatisfy({ $0.asOf.timeIntervalSinceReferenceDate.isFinite }),
              lots.allSatisfy({ $0.acquiredAt.timeIntervalSinceReferenceDate.isFinite }),
              disposals.allSatisfy({ $0.occurredAt.timeIntervalSinceReferenceDate.isFinite }),
              corrections.allSatisfy({ $0.occurredAt.timeIntervalSinceReferenceDate.isFinite }) else {
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
            _ = try InvestmentHolding.positionValue(quantity: quantity, unitPrice: price)
        }
    }

    static func normalizedActivities(
        price: Money?,
        priceAsOf: Date?,
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        corrections: [InvestmentActivityCorrection]
    ) throws -> ValidatedInvestmentActivities {
        var history = priceHistory
        let sequences = priceHistory.map(\.activitySequence)
            + lots.map(\.activitySequence)
            + disposals.map(\.activitySequence)
            + corrections.map(\.activitySequence)
        let implicitSequence = try implicitPriceSequence(sequences)
        if corrections.isEmpty, let price, let priceAsOf,
           !history.contains(where: { $0.price == price && $0.asOf == priceAsOf }),
           let point = try? HoldingPricePoint(
               price: price,
               asOf: priceAsOf,
               activitySequence: implicitSequence
           ) {
            history.append(point)
        }
        let normalized = try InvestmentHolding.normalizedActivitySequences(
            priceHistory: history,
            lots: lots,
            disposals: disposals,
            corrections: corrections
        )
        return ValidatedInvestmentActivities(
            priceHistory: normalized.priceHistory.sorted(by: pricePointOrder),
            lots: normalized.lots.sorted(by: lotOrder),
            disposals: normalized.disposals.sorted(by: disposalOrder),
            corrections: normalized.corrections.sorted {
                $0.activitySequence < $1.activitySequence
            }
        )
    }

    static func validateIdentifiersAndLinks(
        _ activities: ValidatedInvestmentActivities
    ) throws {
        let sourceIDs = activities.priceHistory.map(\.id)
            + activities.lots.map(\.id)
            + activities.disposals.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count,
              Set(activities.corrections.map(\.id)).count == activities.corrections.count,
              Set(activities.corrections.map(\.targetActivityID)).count
                == activities.corrections.count else {
            throw InvestmentHoldingError.duplicateIdentifier
        }
        let purchases = activities.lots.compactMap(\.purchaseEntryID)
        let sales = activities.disposals.map(\.saleEntryID)
        let prices = activities.priceHistory.compactMap(\.priceEntryID)
        let corrections = activities.corrections.compactMap(\.correctionEntryID)
        guard Set(purchases + sales + corrections).count
                == purchases.count + sales.count + corrections.count,
              Set(prices).count == prices.count else {
            throw InvestmentHoldingError.duplicateLinkedEntry
        }
        try validateLinkedPricePoints(activities)
    }

    static func validateCorrections(
        _ activities: ValidatedInvestmentActivities
    ) throws -> Set<UUID> {
        let replacementIDs = Set(activities.corrections.compactMap(\.restorationPricePointID))
        guard replacementIDs.count
                == activities.corrections.compactMap(\.restorationPricePointID).count,
              replacementIDs.isSubset(of: Set(activities.priceHistory.map(\.id))) else {
            throw InvestmentHoldingError.historyMismatch
        }
        var correctedIDs = Set<UUID>()
        var lastDate: Date?
        for (index, correction) in activities.corrections.enumerated() {
            if index.isMultiple(of: 8) { try Task.checkCancellation() }
            try validateCorrection(
                correction,
                activities: activities,
                replacementIDs: replacementIDs,
                correctedIDs: &correctedIDs,
                lastDate: &lastDate
            )
        }
        return correctedIDs
    }

    static func validateValuation(
        quantity: Decimal,
        price: Money?,
        priceAsOf: Date?,
        positionAccountID: UUID?,
        activities: ValidatedInvestmentActivities
    ) throws {
        let currencies = [price?.currency]
            + activities.priceHistory.map { Optional($0.price.currency) }
            + activities.lots.map { Optional($0.unitCost.currency) }
            + activities.disposals.flatMap {
                [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                 Optional($0.realizedGainLoss.currency)]
            }
        guard Set(currencies.compactMap { $0 }).count <= 1 else {
            throw InvestmentHoldingError.valuationCurrencyMismatch
        }
        let effectivePrice = InvestmentHolding.latestEffectivePriceEvent(
            priceHistory: activities.priceHistory,
            lots: activities.lots,
            disposals: activities.disposals,
            corrections: activities.corrections
        )
        let legacyQuote = positionAccountID == nil
            && activities.priceHistory.isEmpty
            && activities.lots.isEmpty
            && activities.disposals.isEmpty
            && activities.corrections.isEmpty
            && price != nil
            && priceAsOf == nil
        if !legacyQuote, price != effectivePrice?.price || priceAsOf != effectivePrice?.asOf {
            throw InvestmentHoldingError.historyMismatch
        }
        guard activities.lots.isEmpty || positionAccountID != nil,
              !(quantity > .zero && activities.lots.isEmpty && positionAccountID != nil) else {
            throw InvestmentHoldingError.historyMismatch
        }
    }

    static func validateLotsAndDisposals(
        _ activities: ValidatedInvestmentActivities
    ) throws {
        for lot in activities.lots {
            _ = try InvestmentHolding.positionValue(
                quantity: lot.originalQuantity,
                unitPrice: lot.unitCost
            )
        }
        for (index, disposal) in activities.disposals.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard disposal.quantity > .zero,
                  disposal.costBasis.amount >= .zero,
                  disposal.proceeds.amount >= .zero,
                  disposal.costBasis.currency == disposal.proceeds.currency,
                  disposal.costBasis.currency == disposal.realizedGainLoss.currency else {
                throw InvestmentHoldingError.invalidDisposal
            }
            let realized = try checkedInvestmentDifference(
                disposal.proceeds.amount,
                disposal.costBasis.amount
            )
            guard disposal.realizedGainLoss.amount
                    == disposal.realizedGainLoss.currency.rounded(realized) else {
                throw InvestmentHoldingError.invalidDisposal
            }
        }
    }

    static func validateHistoricalFIFO(
        _ activities: ValidatedInvestmentActivities
    ) throws {
        var remaining = activities.lots.map(\.originalQuantity)
        for (index, disposal) in activities.disposals.enumerated() {
            if index.isMultiple(of: 8) { try Task.checkCancellation() }
            let result = try consume(
                disposal: disposal,
                lots: activities.lots,
                remaining: remaining
            )
            remaining = result.remaining
            guard result.unconsumed == .zero,
                  disposal.costBasis.amount
                    == disposal.costBasis.currency.rounded(result.basis) else {
                throw InvestmentHoldingError.historyMismatch
            }
        }
    }

    static func validateProjection(
        quantity: Decimal,
        activities: ValidatedInvestmentActivities,
        correctedActivityIDs: Set<UUID>
    ) throws {
        let remaining = try InvestmentHolding.projectedLotRemaining(
            lots: activities.lots,
            disposals: activities.disposals,
            correctedActivityIDs: correctedActivityIDs
        )
        guard zip(remaining, activities.lots).allSatisfy({ $0.0 == $0.1.remainingQuantity }) else {
            throw InvestmentHoldingError.historyMismatch
        }
        guard !activities.lots.isEmpty else { return }
        var projectedQuantity = Decimal.zero
        for value in remaining {
            projectedQuantity = try checkedInvestmentSum(projectedQuantity, value)
        }
        guard projectedQuantity == quantity else {
            throw InvestmentHoldingError.lotQuantityMismatch
        }
    }

    private static func implicitPriceSequence(_ sequences: [Int64]) throws -> Int64 {
        if sequences.isEmpty || sequences.allSatisfy({ $0 == 0 }) { return 0 }
        guard let maximum = sequences.max(), maximum < Int64.max else {
            throw InvestmentHoldingError.arithmeticOverflow
        }
        return maximum + 1
    }

    private static func pricePointOrder(_ left: HoldingPricePoint, _ right: HoldingPricePoint) -> Bool {
        left.asOf == right.asOf
            ? left.activitySequence < right.activitySequence
            : left.asOf < right.asOf
    }

    private static func lotOrder(_ left: InvestmentLot, _ right: InvestmentLot) -> Bool {
        left.acquiredAt == right.acquiredAt
            ? left.activitySequence < right.activitySequence
            : left.acquiredAt < right.acquiredAt
    }

    private static func disposalOrder(
        _ left: InvestmentDisposal,
        _ right: InvestmentDisposal
    ) -> Bool {
        left.occurredAt == right.occurredAt
            ? left.activitySequence < right.activitySequence
            : left.occurredAt < right.occurredAt
    }

    private static func validateLinkedPricePoints(
        _ activities: ValidatedInvestmentActivities
    ) throws {
        var linked = Dictionary(
            uniqueKeysWithValues: activities.lots.compactMap { lot in
                lot.purchaseEntryID.map { ($0, (lot.acquiredAt, lot.activitySequence)) }
            } + activities.disposals.map {
                ($0.saleEntryID, ($0.occurredAt, $0.activitySequence))
            }
        )
        for (index, correction) in activities.corrections.enumerated() {
            if index.isMultiple(of: 8) { try Task.checkCancellation() }
            if let entryID = correction.correctionEntryID {
                linked[entryID] = (correction.occurredAt, correction.activitySequence)
            }
        }
        for point in activities.priceHistory {
            guard let entryID = point.priceEntryID,
                  let activity = linked[entryID] else { continue }
            let next = activity.1.addingReportingOverflow(1)
            guard !next.overflow,
                  point.asOf == activity.0,
                  point.activitySequence == next.partialValue else {
                throw InvestmentHoldingError.historyMismatch
            }
        }
    }

    private static func validateCorrection(
        _ correction: InvestmentActivityCorrection,
        activities: ValidatedInvestmentActivities,
        replacementIDs: Set<UUID>,
        correctedIDs: inout Set<UUID>,
        lastDate: inout Date?
    ) throws {
        let history = activities.priceHistory.filter {
            $0.activitySequence < correction.activitySequence
        }
        let lots = activities.lots.filter {
            $0.activitySequence < correction.activitySequence
        }
        let disposals = activities.disposals.filter {
            $0.activitySequence < correction.activitySequence
        }
        guard let target = InvestmentHolding.latestSourceTarget(
            priceHistory: history,
            lots: lots,
            disposals: disposals,
            correctedActivityIDs: correctedIDs,
            replacementPricePointIDs: replacementIDs
        ), target.target.id == correction.targetActivityID,
           target.target.kind == correction.kind,
           target.target.linkedEntryID == correction.targetEntryID,
           correction.activitySequence > target.logicalSequence,
           correction.occurredAt >= target.target.occurredAt,
           lastDate.map({ correction.occurredAt >= $0 }) ?? true,
           (correction.targetEntryID == nil) == (correction.correctionEntryID == nil) else {
            throw InvestmentHoldingError.historyMismatch
        }
        correctedIDs.insert(correction.targetActivityID)
        let previous = InvestmentHolding.latestActiveSourcePricePoint(
            priceHistory: history,
            lots: lots,
            disposals: disposals,
            correctedActivityIDs: correctedIDs,
            replacementPricePointIDs: replacementIDs
        )
        try validateRestoration(correction, previous: previous, history: activities.priceHistory)
        lastDate = correction.occurredAt
    }

    private static func validateRestoration(
        _ correction: InvestmentActivityCorrection,
        previous: HoldingPricePoint?,
        history: [HoldingPricePoint]
    ) throws {
        guard let previous else {
            if correction.restorationPricePointID != nil {
                throw InvestmentHoldingError.historyMismatch
            }
            return
        }
        let next = correction.activitySequence.addingReportingOverflow(1)
        guard let restorationID = correction.restorationPricePointID,
              let restoration = history.first(where: { $0.id == restorationID }),
              restoration.price == previous.price,
              restoration.asOf == correction.occurredAt,
              restoration.priceEntryID == correction.correctionEntryID,
              restoration.activitySequence == next.partialValue,
              !next.overflow else {
            throw InvestmentHoldingError.historyMismatch
        }
    }

    private static func consume(
        disposal: InvestmentDisposal,
        lots: [InvestmentLot],
        remaining: [Decimal]
    ) throws -> (remaining: [Decimal], unconsumed: Decimal, basis: Decimal) {
        var updated = remaining
        var unconsumed = disposal.quantity
        var basis = Decimal.zero
        for index in lots.indices where unconsumed > .zero {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let precedes = lots[index].acquiredAt < disposal.occurredAt
                || (lots[index].acquiredAt == disposal.occurredAt
                    && lots[index].activitySequence < disposal.activitySequence)
            guard precedes else { continue }
            let quantity = min(updated[index], unconsumed)
            updated[index] = try checkedInvestmentDifference(updated[index], quantity)
            unconsumed = try checkedInvestmentDifference(unconsumed, quantity)
            basis = try checkedInvestmentSum(
                basis,
                checkedInvestmentProduct(quantity, lots[index].unitCost.amount)
            )
        }
        return (updated, unconsumed, basis)
    }
}
