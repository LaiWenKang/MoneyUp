import Foundation

public struct CurrencyNetWorth: Codable, Equatable, Identifiable, Sendable {
    public var id: CurrencyCode { money.currency }
    public let money: Money

    public init(_ money: Money) { self.money = money }
}

public enum NetWorthSnapshotError: Error, Equatable, Sendable {
    case duplicateCurrency
    case invalidConversion
    case incompleteConversion
    case inconsistentEstimate
    case arithmeticOverflow
}

/// Frozen evidence for one non-base component of a combined estimate. The
/// applied rate is copied into the snapshot so editing or deleting the source
/// rate later cannot rewrite—or make the historical estimate unexplainable.
public struct NetWorthConversionEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: CurrencyCode { source.currency }
    public let source: Money
    public let appliedRate: Decimal
    public let rateID: UUID
    public let effectiveDayKey: Int
    public let usedInverseRate: Bool
    public let converted: Money

    public init(
        source: Money,
        appliedRate: Decimal,
        rateID: UUID,
        effectiveDayKey: Int,
        usedInverseRate: Bool,
        converted: Money
    ) throws {
        guard source.currency != converted.currency,
              source.amount != .zero,
              appliedRate > .zero,
              !appliedRate.isNaN,
              effectiveDayKey > 0 else {
            throw NetWorthSnapshotError.invalidConversion
        }
        var sourceAmount = source.amount
        var rate = appliedRate
        var raw = Decimal.zero
        let error = NSDecimalMultiply(&raw, &sourceAmount, &rate, .bankers)
        guard (error == .noError || error == .lossOfPrecision),
              !raw.isNaN,
              raw != .zero,
              converted.currency.rounded(raw) == converted.amount,
              converted.amount != .zero else {
            throw NetWorthSnapshotError.invalidConversion
        }
        self.source = source
        self.appliedRate = appliedRate
        self.rateID = rateID
        self.effectiveDayKey = effectiveDayKey
        self.usedInverseRate = usedInverseRate
        self.converted = converted
    }

    private enum CodingKeys: String, CodingKey {
        case source, appliedRate, rateID, effectiveDayKey, usedInverseRate, converted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                source: container.decode(Money.self, forKey: .source),
                appliedRate: container.decode(Decimal.self, forKey: .appliedRate),
                rateID: container.decode(UUID.self, forKey: .rateID),
                effectiveDayKey: container.decode(Int.self, forKey: .effectiveDayKey),
                usedInverseRate: container.decode(Bool.self, forKey: .usedInverseRate),
                converted: container.decode(Money.self, forKey: .converted)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .converted,
                in: container,
                debugDescription: "Invalid frozen net-worth conversion evidence."
            )
        }
    }
}

/// A frozen, append-only net-worth observation. Later price or exchange-rate
/// edits do not rewrite it, which keeps the historical series explainable.
public struct NetWorthSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let amounts: [CurrencyNetWorth]
    public let estimatedBaseTotal: Money?
    public let conversionAsOf: Date?
    public let conversionAsOfDayKey: Int?
    public let conversionEvidence: [NetWorthConversionEvidence]

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        amounts: [Money],
        estimatedBaseTotal: Money? = nil,
        conversionAsOf: Date? = nil,
        conversionAsOfDayKey: Int? = nil,
        conversionEvidence: [NetWorthConversionEvidence] = []
    ) throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NetWorthSnapshotError.inconsistentEstimate
        }
        try Self.validateUniqueCurrencies(amounts)
        try Self.validateEstimate(
            amounts: amounts,
            estimatedBaseTotal: estimatedBaseTotal,
            conversionAsOf: conversionAsOf,
            conversionAsOfDayKey: conversionAsOfDayKey,
            conversionEvidence: conversionEvidence,
            permitsLegacyMissingEvidence: false
        )
        self.id = id
        self.capturedAt = capturedAt
        self.amounts = amounts.sorted { $0.currency < $1.currency }.map(CurrencyNetWorth.init)
        self.estimatedBaseTotal = estimatedBaseTotal
        self.conversionAsOf = conversionAsOf
        self.conversionAsOfDayKey = conversionAsOfDayKey
        self.conversionEvidence = conversionEvidence.sorted { $0.source.currency < $1.source.currency }
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, amounts, estimatedBaseTotal, conversionAsOf
        case conversionAsOfDayKey, conversionEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedAmounts = try container.decode([CurrencyNetWorth].self, forKey: .amounts)
            .map(\.money)
        let estimate = try container.decodeIfPresent(Money.self, forKey: .estimatedBaseTotal)
        let asOf = try container.decodeIfPresent(Date.self, forKey: .conversionAsOf)
        let asOfDayKey = try container.decodeIfPresent(Int.self, forKey: .conversionAsOfDayKey)
        let evidenceWasStored = container.contains(.conversionEvidence)
        let evidence = try container.decodeIfPresent(
            [NetWorthConversionEvidence].self,
            forKey: .conversionEvidence
        ) ?? []
        do {
            try Self.validateUniqueCurrencies(decodedAmounts)
            try Self.validateEstimate(
                amounts: decodedAmounts,
                estimatedBaseTotal: estimate,
                conversionAsOf: asOf,
                conversionAsOfDayKey: asOfDayKey,
                conversionEvidence: evidence,
                permitsLegacyMissingEvidence: !evidenceWasStored
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .amounts,
                in: container,
                debugDescription: "Invalid frozen net-worth snapshot."
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        let decodedCapturedAt = try container.decode(Date.self, forKey: .capturedAt)
        guard decodedCapturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .capturedAt,
                in: container,
                debugDescription: "Invalid net-worth snapshot capture date."
            )
        }
        capturedAt = decodedCapturedAt
        amounts = decodedAmounts.sorted { $0.currency < $1.currency }.map(CurrencyNetWorth.init)
        estimatedBaseTotal = estimate
        conversionAsOf = asOf
        conversionAsOfDayKey = asOfDayKey
        conversionEvidence = evidence.sorted { $0.source.currency < $1.source.currency }
    }

    private static func validateUniqueCurrencies(_ amounts: [Money]) throws {
        guard Set(amounts.map(\.currency)).count == amounts.count else {
            throw NetWorthSnapshotError.duplicateCurrency
        }
    }

    private static func validateEstimate(
        amounts: [Money],
        estimatedBaseTotal: Money?,
        conversionAsOf: Date?,
        conversionAsOfDayKey: Int?,
        conversionEvidence: [NetWorthConversionEvidence],
        permitsLegacyMissingEvidence: Bool
    ) throws {
        guard let estimatedBaseTotal else {
            guard conversionAsOf == nil,
                  conversionAsOfDayKey == nil,
                  conversionEvidence.isEmpty else {
                throw NetWorthSnapshotError.inconsistentEstimate
            }
            return
        }
        if permitsLegacyMissingEvidence,
           conversionEvidence.isEmpty,
           conversionAsOfDayKey == nil {
            guard conversionAsOf != nil else {
                throw NetWorthSnapshotError.inconsistentEstimate
            }
            return
        }
        guard let conversionAsOf,
              let conversionAsOfDayKey,
              conversionAsOf.timeIntervalSinceReferenceDate.isFinite,
              !conversionEvidence.isEmpty,
              Set(conversionEvidence.map { $0.source.currency }).count
                == conversionEvidence.count,
              conversionAsOfDayKey == conversionEvidence.map(\.effectiveDayKey).min() else {
            throw NetWorthSnapshotError.inconsistentEstimate
        }

        let amountByCurrency = Dictionary(uniqueKeysWithValues: amounts.map {
            ($0.currency, $0)
        })
        let foreign = amounts.filter {
            $0.currency != estimatedBaseTotal.currency && !$0.isZero
        }
        guard Set(foreign.map(\.currency))
                == Set(conversionEvidence.map { $0.source.currency }),
              conversionEvidence.allSatisfy({ evidence in
                  amountByCurrency[evidence.source.currency] == evidence.source
                      && evidence.converted.currency == estimatedBaseTotal.currency
              }) else {
            throw NetWorthSnapshotError.incompleteConversion
        }

        var expectedTotal = amountByCurrency[estimatedBaseTotal.currency]?.amount ?? .zero
        for evidence in conversionEvidence {
            var converted = evidence.converted.amount
            var result = Decimal.zero
            let error = NSDecimalAdd(&result, &expectedTotal, &converted, .bankers)
            guard error == .noError, !result.isNaN else {
                throw NetWorthSnapshotError.arithmeticOverflow
            }
            expectedTotal = result
        }
        guard expectedTotal == estimatedBaseTotal.amount else {
            throw NetWorthSnapshotError.inconsistentEstimate
        }
    }
}
