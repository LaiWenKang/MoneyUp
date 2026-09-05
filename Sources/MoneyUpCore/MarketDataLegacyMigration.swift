import Foundation

public enum LegacyMarketDataResolutionReason: String, Equatable, Sendable {
    case missingQuoteCurrency
    case invalidSymbol
}

public struct ManualLegacyMarketDataMapping: Equatable, Sendable {
    public let instrument: InstrumentIdentity
    public let observations: [MarketQuoteObservation]
    /// True only when the legacy holding has a current price but no honest
    /// price timestamp. The value remains in its old record for user review;
    /// migration does not invent an `asOf` date.
    public let omittedUndatedCurrentPrice: Bool

    public init(
        instrument: InstrumentIdentity,
        observations: [MarketQuoteObservation],
        omittedUndatedCurrentPrice: Bool
    ) {
        self.instrument = instrument
        self.observations = observations
        self.omittedUndatedCurrentPrice = omittedUndatedCurrentPrice
    }
}

public enum LegacyMarketDataMigrationResult: Equatable, Sendable {
    case mapped(ManualLegacyMarketDataMapping)
    case needsResolution(LegacyMarketDataResolutionReason)
}

public enum LegacyMarketDataMigration {
    /// Maps dated local price evidence without mutating or deleting the legacy
    /// holding. Holding UUID becomes the stable instrument UUID, avoiding a
    /// second identity that could make the same position appear twice.
    public static func map(
        holding: InvestmentHolding
    ) throws -> LegacyMarketDataMigrationResult {
        guard let currency = holding.valuationCurrency else {
            return .needsResolution(.missingQuoteCurrency)
        }
        let instrument: InstrumentIdentity
        do {
            instrument = try InstrumentIdentity(
                id: holding.id,
                kind: .other,
                symbol: holding.symbol,
                venue: nil,
                quoteCurrency: currency,
                resolution: .manualLegacy
            )
        } catch MarketDataModelError.invalidSymbol {
            return .needsResolution(.invalidSymbol)
        }
        let session = try MarketSessionContext(state: .unknown)
        let effectiveDatedHistory = effectiveDatedHistory(for: holding)
        let observations = try effectiveDatedHistory.map { point in
            try MarketQuoteObservation(
                id: point.id,
                instrument: instrument,
                unitPrice: point.price,
                marketTimestamp: point.asOf,
                receivedAt: point.asOf,
                quoteType: .manual,
                delay: .notApplicable,
                quality: .legacy,
                session: session,
                provenance: try MarketQuoteProvenance(
                    sourceKind: .manualLegacy,
                    sourceIdentifier: "moneyup.manual-legacy",
                    sourceRecordIdentifier: point.id.uuidString,
                    sourceSequence: point.activitySequence
                )
            )
        }
        return .mapped(ManualLegacyMarketDataMapping(
            instrument: instrument,
            observations: MarketQuoteResolver.deduplicate(observations),
            omittedUndatedCurrentPrice: holding.price != nil
                && holding.priceAsOf == nil
        ))
    }

    private static func effectiveDatedHistory(
        for holding: InvestmentHolding
    ) -> [HoldingPricePoint] {
        let correctedValuationPointIDs = Set(
            holding.corrections.lazy
                .filter { $0.kind == .valuation }
                .map(\.targetActivityID)
        )
        let correctedTradeEntryIDs = Set(
            holding.corrections.lazy
                .filter { $0.kind == .purchase || $0.kind == .sale }
                .compactMap(\.targetEntryID)
        )
        let restorationPricePointIDs = Set(
            holding.corrections.compactMap(\.restorationPricePointID)
        )
        let effectiveEvent = InvestmentHolding.latestEffectivePriceEvent(
            priceHistory: holding.priceHistory,
            lots: holding.lots,
            disposals: holding.disposals,
            corrections: holding.corrections
        )
        let effectiveRestorationPricePointID = holding.priceHistory.first {
            restorationPricePointIDs.contains($0.id)
                && $0.activitySequence == effectiveEvent?.sequence
        }?.id
        let activePriceHistory = holding.priceHistory.filter { point in
            if restorationPricePointIDs.contains(point.id) {
                return point.id == effectiveRestorationPricePointID
            }
            guard !correctedValuationPointIDs.contains(point.id) else {
                return false
            }
            guard let priceEntryID = point.priceEntryID else { return true }
            return !correctedTradeEntryIDs.contains(priceEntryID)
        }
        let effectiveDatedHistory = activePriceHistory.sorted {
            if $0.asOf != $1.asOf { return $0.asOf < $1.asOf }
            return $0.activitySequence < $1.activitySequence
        }
        return effectiveDatedHistory
    }
}
