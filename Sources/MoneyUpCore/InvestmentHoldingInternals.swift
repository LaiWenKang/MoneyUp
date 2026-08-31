import Foundation

extension InvestmentHolding {
    var valuationCurrency: CurrencyCode? {
        price?.currency
            ?? priceHistory.last?.price.currency
            ?? lots.first?.unitCost.currency
            ?? disposals.first?.proceeds.currency
    }

    struct SourceTargetCandidate {
        let target: InvestmentCorrectionTarget
        let logicalSequence: Int64
    }

    struct EffectivePriceEvent {
        let sequence: Int64
        let price: Money?
        let asOf: Date?
    }

    static func latestSourceTarget(
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
        let priceSequenceByEntry = Dictionary(
            priceHistory.compactMap { point in
                point.priceEntryID.map { ($0, point.activitySequence) }
            },
            uniquingKeysWith: max
        )
        var candidates: [SourceTargetCandidate] = []
        for lot in lots where !correctedActivityIDs.contains(lot.id) {
            let pairedSequence = lot.purchaseEntryID.flatMap {
                priceSequenceByEntry[$0]
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
            let pairedSequence = priceSequenceByEntry[disposal.saleEntryID]
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

    static func latestActiveSourcePricePoint(
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

    static func latestEffectivePriceEvent(
        priceHistory: [HoldingPricePoint],
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        corrections: [InvestmentActivityCorrection]
    ) -> EffectivePriceEvent? {
        let correctedIDs = Set(corrections.map(\.targetActivityID))
        let replacementIDs = Set(corrections.compactMap(\.restorationPricePointID))
        let purchaseTargetByEntry = Dictionary(
            uniqueKeysWithValues: lots.compactMap { lot in
                lot.purchaseEntryID.map { ($0, lot.id) }
            }
        )
        let saleTargetByEntry = Dictionary(
            uniqueKeysWithValues: disposals.map { ($0.saleEntryID, $0.id) }
        )
        let historyByID = Dictionary(
            uniqueKeysWithValues: priceHistory.map { ($0.id, $0) }
        )
        var events = priceHistory.compactMap { point -> EffectivePriceEvent? in
            guard !replacementIDs.contains(point.id),
                  !correctedIDs.contains(point.id) else { return nil }
            if let entryID = point.priceEntryID {
                if let targetID = purchaseTargetByEntry[entryID],
                   correctedIDs.contains(targetID) {
                    return nil
                }
                if let targetID = saleTargetByEntry[entryID],
                   correctedIDs.contains(targetID) {
                    return nil
                }
            }
            return EffectivePriceEvent(
                sequence: point.activitySequence,
                price: point.price,
                asOf: point.asOf
            )
        }
        for correction in corrections {
            if let restorationID = correction.restorationPricePointID,
               let point = historyByID[restorationID] {
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

    static func projectedLotRemaining(
        lots: [InvestmentLot],
        disposals: [InvestmentDisposal],
        correctedActivityIDs: Set<UUID>
    ) throws -> [Decimal] {
        var remaining = lots.map { lot in
            correctedActivityIDs.contains(lot.id) ? Decimal.zero : lot.originalQuantity
        }
        var disposalIteration = 0
        for disposal in disposals where !correctedActivityIDs.contains(disposal.id) {
            if disposalIteration.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
            disposalIteration += 1
            var remainingToConsume = disposal.quantity
            for index in lots.indices where remainingToConsume > .zero {
                if index.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
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

    static func normalizedActivitySequences(
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
                migratedDisposals[slot.index] = try InvestmentDisposal(
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

    func nextActivitySequence() throws -> Int64 {
        let maximum = (priceHistory.map(\.activitySequence)
            + lots.map(\.activitySequence)
            + disposals.map(\.activitySequence)
            + corrections.map(\.activitySequence)).max() ?? 0
        guard maximum < Int64.max else {
            throw InvestmentHoldingError.arithmeticOverflow
        }
        return maximum + 1
    }

    func requireChronologicalActivity(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw InvestmentHoldingError.historyMismatch
        }
        if let latestActivityDate, date < latestActivityDate {
            throw InvestmentHoldingError.activityOutOfOrder
        }
    }

    enum CodingKeys: String, CodingKey {
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
