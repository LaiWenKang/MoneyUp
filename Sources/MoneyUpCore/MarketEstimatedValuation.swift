import Foundation

public enum MarketValuationError: Error, Equatable, Sendable {
    case invalidDate
    case invalidPosition
    case duplicateRecordedCurrency
    case duplicateHolding
    case duplicateLedgerPositionAccount
    case recordedPositionCurrencyMismatch
    case recordedPositionCurrencyMissing(CurrencyCode)
    case arithmeticOverflow
    case conversionFailed(CurrencyCode)
}

public enum MarketValuationLedgerCoverage: Equatable, Sendable {
    /// The amount is already included in recorded net worth. Estimation must
    /// subtract it before adding the market value, so the asset is counted once.
    case replaceRecordedPosition(accountID: UUID, value: Money)
    /// Explicit user confirmation that this legacy position is absent from all
    /// recorded asset balances. This is never inferred from a missing link.
    case addConfirmedLegacyPosition
}

public struct MarketValuationPosition: Equatable, Identifiable, Sendable {
    public var id: UUID { holdingID }
    public let holdingID: UUID
    public let instrument: InstrumentIdentity
    public let quantity: Decimal
    public let ledgerCoverage: MarketValuationLedgerCoverage

    public init(
        holdingID: UUID,
        instrument: InstrumentIdentity,
        quantity: Decimal,
        ledgerCoverage: MarketValuationLedgerCoverage
    ) throws {
        guard quantity > .zero, !quantity.isNaN else {
            throw MarketValuationError.invalidPosition
        }
        if case let .replaceRecordedPosition(_, value) = ledgerCoverage {
            guard value.amount >= .zero,
                  value.currency == instrument.quoteCurrency else {
                throw MarketValuationError.recordedPositionCurrencyMismatch
            }
        }
        self.holdingID = holdingID
        self.instrument = instrument
        self.quantity = quantity
        self.ledgerCoverage = ledgerCoverage
    }
}

public enum MarketValuationGapReason: Equatable, Sendable {
    case quoteUnavailable(MarketQuoteSelectionFailure)
}

public struct MarketValuationGap: Equatable, Identifiable, Sendable {
    public var id: UUID { holdingID }
    public let holdingID: UUID
    public let instrumentID: UUID
    public let reason: MarketValuationGapReason

    public init(
        holdingID: UUID,
        instrumentID: UUID,
        reason: MarketValuationGapReason
    ) {
        self.holdingID = holdingID
        self.instrumentID = instrumentID
        self.reason = reason
    }
}

public struct MarketValuationEvidence: Equatable, Identifiable, Sendable {
    public var id: UUID { holdingID }
    public let holdingID: UUID
    public let positionAccountID: UUID?
    public let instrumentID: UUID
    public let quoteObservationID: UUID
    public let quantity: Decimal
    public let unitPrice: Money
    public let recordedValueReplaced: Money?
    public let estimatedValue: Money
    public let freshness: MarketQuoteFreshness

    public init(
        holdingID: UUID,
        positionAccountID: UUID?,
        instrumentID: UUID,
        quoteObservationID: UUID,
        quantity: Decimal,
        unitPrice: Money,
        recordedValueReplaced: Money?,
        estimatedValue: Money,
        freshness: MarketQuoteFreshness
    ) {
        self.holdingID = holdingID
        self.positionAccountID = positionAccountID
        self.instrumentID = instrumentID
        self.quoteObservationID = quoteObservationID
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.recordedValueReplaced = recordedValueReplaced
        self.estimatedValue = estimatedValue
        self.freshness = freshness
    }
}

public enum MarketValuationCompleteness: String, Equatable, Sendable {
    case complete
    case completeWithStaleEvidence
    case partial
    case unavailable
}

public struct MarketValuationConversionContext: Sendable {
    public let baseCurrency: CurrencyCode
    public let origin: TransactionOriginContext
    public let rates: [DatedExchangeRate]

    public init(
        baseCurrency: CurrencyCode,
        origin: TransactionOriginContext,
        rates: [DatedExchangeRate]
    ) {
        self.baseCurrency = baseCurrency
        self.origin = origin
        self.rates = rates
    }
}

public struct MarketEstimatedNetWorth: Equatable, Sendable {
    /// Authoritative ledger result before temporary market substitutions.
    public let recordedAmounts: [CurrencyNetWorth]
    /// Currency-separated estimate; gaps retain the relevant recorded value.
    public let amounts: [CurrencyNetWorth]
    public let evidence: [MarketValuationEvidence]
    public let gaps: [MarketValuationGap]
    public let completeness: MarketValuationCompleteness
    public let baseCurrency: CurrencyCode?
    /// Nil unless every non-zero currency can be converted. Partial sums are
    /// forbidden because they look complete while silently dropping assets.
    public let estimatedBaseTotal: Money?
    public let missingConversionCurrencies: [CurrencyCode]
    public let conversionEvidence: [NetWorthConversionEvidence]

    public init(
        recordedAmounts: [CurrencyNetWorth],
        amounts: [CurrencyNetWorth],
        evidence: [MarketValuationEvidence],
        gaps: [MarketValuationGap],
        completeness: MarketValuationCompleteness,
        baseCurrency: CurrencyCode?,
        estimatedBaseTotal: Money?,
        missingConversionCurrencies: [CurrencyCode],
        conversionEvidence: [NetWorthConversionEvidence]
    ) {
        self.recordedAmounts = recordedAmounts
        self.amounts = amounts
        self.evidence = evidence
        self.gaps = gaps
        self.completeness = completeness
        self.baseCurrency = baseCurrency
        self.estimatedBaseTotal = estimatedBaseTotal
        self.missingConversionCurrencies = missingConversionCurrencies
        self.conversionEvidence = conversionEvidence
    }
}

public enum MarketEstimatedNetWorthEngine {
    public static func estimate(
        recordedAmounts: [Money],
        positions: [MarketValuationPosition],
        observations: [MarketQuoteObservation],
        at valuationDate: Date,
        policy: MarketDataPolicy = .manualLocalDefault,
        conversion: MarketValuationConversionContext? = nil
    ) throws -> MarketEstimatedNetWorth {
        guard valuationDate.timeIntervalSinceReferenceDate.isFinite else {
            throw MarketValuationError.invalidDate
        }
        try validateUniqueInputs(recordedAmounts: recordedAmounts, positions: positions)
        var totals = Dictionary(uniqueKeysWithValues: recordedAmounts.map {
            ($0.currency, $0.amount)
        })
        var evidence: [MarketValuationEvidence] = []
        var gaps: [MarketValuationGap] = []
        for position in positions.sorted(by: positionOrder) {
            let resolution = MarketQuoteResolver.latest(
                for: position.instrument,
                observations: observations,
                at: valuationDate,
                policy: policy
            )
            switch resolution {
            case let .selected(assessment):
                let item = try apply(
                    position: position,
                    assessment: assessment,
                    totals: &totals
                )
                evidence.append(item)
            case let .unavailable(reason):
                gaps.append(MarketValuationGap(
                    holdingID: position.holdingID,
                    instrumentID: position.instrument.id,
                    reason: .quoteUnavailable(reason)
                ))
            }
        }
        let amountRows = try totals.sorted { $0.key < $1.key }.map {
            try Money($0.value, currency: $0.key)
        }
        let combined = try combinedEstimate(amounts: amountRows, conversion: conversion)
        return MarketEstimatedNetWorth(
            recordedAmounts: recordedAmounts.sorted { $0.currency < $1.currency }
                .map(CurrencyNetWorth.init),
            amounts: amountRows.map(CurrencyNetWorth.init),
            evidence: evidence,
            gaps: gaps,
            completeness: completeness(
                positionCount: positions.count,
                evidence: evidence,
                gaps: gaps
            ),
            baseCurrency: conversion?.baseCurrency,
            estimatedBaseTotal: combined.total,
            missingConversionCurrencies: combined.missing,
            conversionEvidence: combined.evidence
        )
    }

    private static func validateUniqueInputs(
        recordedAmounts: [Money],
        positions: [MarketValuationPosition]
    ) throws {
        guard Set(recordedAmounts.map(\.currency)).count == recordedAmounts.count else {
            throw MarketValuationError.duplicateRecordedCurrency
        }
        guard Set(positions.map(\.holdingID)).count == positions.count else {
            throw MarketValuationError.duplicateHolding
        }
        let accountIDs = positions.compactMap { position -> UUID? in
            if case let .replaceRecordedPosition(accountID, _) = position.ledgerCoverage {
                return accountID
            }
            return nil
        }
        guard Set(accountIDs).count == accountIDs.count else {
            throw MarketValuationError.duplicateLedgerPositionAccount
        }
        let recordedCurrencies = Set(recordedAmounts.map(\.currency))
        for position in positions {
            if case let .replaceRecordedPosition(_, value) = position.ledgerCoverage,
               !recordedCurrencies.contains(value.currency) {
                throw MarketValuationError.recordedPositionCurrencyMissing(value.currency)
            }
        }
    }

    private static func apply(
        position: MarketValuationPosition,
        assessment: MarketQuoteAssessment,
        totals: inout [CurrencyCode: Decimal]
    ) throws -> MarketValuationEvidence {
        let quote = assessment.observation
        let estimatedAmount: Decimal
        do {
            estimatedAmount = try CheckedDecimal.productForCurrencyRounding(
                position.quantity,
                quote.unitPrice.amount,
                currency: quote.unitPrice.currency
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MarketValuationError.arithmeticOverflow
        }
        let estimatedValue = try Money(
            estimatedAmount,
            currency: quote.unitPrice.currency
        )
        let coverage = try applyLedgerCoverage(
            position.ledgerCoverage,
            estimatedValue: estimatedValue,
            totals: &totals
        )
        return MarketValuationEvidence(
            holdingID: position.holdingID,
            positionAccountID: coverage.accountID,
            instrumentID: position.instrument.id,
            quoteObservationID: quote.id,
            quantity: position.quantity,
            unitPrice: quote.unitPrice,
            recordedValueReplaced: coverage.replaced,
            estimatedValue: estimatedValue,
            freshness: assessment.freshness
        )
    }

    private static func applyLedgerCoverage(
        _ coverage: MarketValuationLedgerCoverage,
        estimatedValue: Money,
        totals: inout [CurrencyCode: Decimal]
    ) throws -> (accountID: UUID?, replaced: Money?) {
        let currency = estimatedValue.currency
        let current = totals[currency] ?? .zero
        do {
            switch coverage {
            case let .replaceRecordedPosition(accountID, recordedValue):
                let withoutRecorded = try CheckedDecimal.subtracting(
                    current,
                    recordedValue.amount
                )
                totals[currency] = try CheckedDecimal.adding(
                    withoutRecorded,
                    estimatedValue.amount
                )
                return (accountID, recordedValue)
            case .addConfirmedLegacyPosition:
                totals[currency] = try CheckedDecimal.adding(
                    current,
                    estimatedValue.amount
                )
                return (nil, nil)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MarketValuationError.arithmeticOverflow
        }
    }

    private static func combinedEstimate(
        amounts: [Money],
        conversion: MarketValuationConversionContext?
    ) throws -> (
        total: Money?,
        missing: [CurrencyCode],
        evidence: [NetWorthConversionEvidence]
    ) {
        guard let conversion else { return (nil, [], []) }
        var total = Decimal.zero
        var missing: [CurrencyCode] = []
        var evidence: [NetWorthConversionEvidence] = []
        for amount in amounts where !amount.isZero {
            if amount.currency == conversion.baseCurrency {
                total = try addConversionAmount(total, amount.amount)
                continue
            }
            guard let item = try conversionEvidence(
                amount: amount,
                context: conversion
            ) else {
                missing.append(amount.currency)
                continue
            }
            total = try addConversionAmount(total, item.converted.amount)
            evidence.append(item)
        }
        guard missing.isEmpty else {
            return (nil, missing.sorted(), evidence.sorted {
                $0.source.currency < $1.source.currency
            })
        }
        return (
            try Money(total, currency: conversion.baseCurrency),
            [],
            evidence.sorted { $0.source.currency < $1.source.currency }
        )
    }

    private static func conversionEvidence(
        amount: Money,
        context: MarketValuationConversionContext
    ) throws -> NetWorthConversionEvidence? {
        do {
            guard let converted = try HistoricalExchangeRateLookup.conversion(
                of: amount,
                to: context.baseCurrency,
                on: context.origin,
                rates: context.rates
            ) else { return nil }
            return try NetWorthConversionEvidence(
                source: amount,
                appliedRate: converted.appliedRate,
                rateID: converted.rateID,
                effectiveDayKey: converted.effectiveDayKey,
                usedInverseRate: converted.usedInverseRate,
                converted: converted.converted
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MarketValuationError.conversionFailed(amount.currency)
        }
    }

    private static func addConversionAmount(
        _ total: Decimal,
        _ amount: Decimal
    ) throws -> Decimal {
        do {
            return try CheckedDecimal.adding(total, amount)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MarketValuationError.arithmeticOverflow
        }
    }

    private static func completeness(
        positionCount: Int,
        evidence: [MarketValuationEvidence],
        gaps: [MarketValuationGap]
    ) -> MarketValuationCompleteness {
        if !gaps.isEmpty {
            return evidence.isEmpty && positionCount > 0 ? .unavailable : .partial
        }
        let hasStale = evidence.contains { $0.freshness == .stale }
        return hasStale ? .completeWithStaleEvidence : .complete
    }

    private static func positionOrder(
        _ left: MarketValuationPosition,
        _ right: MarketValuationPosition
    ) -> Bool {
        left.holdingID.uuidString < right.holdingID.uuidString
    }
}
