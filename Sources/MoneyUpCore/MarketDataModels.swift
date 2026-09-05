import Foundation

public enum MarketDataModelError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidSymbol
    case invalidVenue
    case invalidSource
    case invalidPrice
    case currencyMismatch
    case invalidTimestamp
    case invalidDelay
    case inconsistentSession
    case inconsistentProvenance
}

enum MarketDataIdentifierNormalizer {
    static func providerIdentifier(_ rawValue: String) throws -> String {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let validBytes = value.utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }
        guard (1...64).contains(value.utf8.count), validBytes else {
            throw MarketDataModelError.invalidIdentifier
        }
        return value
    }
}

public enum MarketInstrumentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case equity
    case exchangeTradedFund
    case mutualFund
    case bond
    case digitalAsset
    case commodity
    case index
    case other
}

public enum MarketInstrumentResolution: String, Codable, Hashable, Sendable {
    /// Symbol, venue, and quote currency have been explicitly confirmed.
    case resolved
    /// A local holding was migrated without inventing an exchange or provider ID.
    case manualLegacy
}

public enum MarketVenueKind: String, Codable, Hashable, Sendable {
    /// ISO 10383 Market Identifier Code.
    case mic
    /// A provider-neutral venue code for markets without a useful MIC.
    case other
}

public struct MarketVenue: Codable, Equatable, Hashable, Sendable {
    public let kind: MarketVenueKind
    public let code: String

    public init(kind: MarketVenueKind, code: String) throws {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let validBytes = normalized.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (48...57).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }
        let validCount = kind == .mic
            ? normalized.utf8.count == 4
            : (2...16).contains(normalized.utf8.count)
        guard validBytes, validCount else {
            throw MarketDataModelError.invalidVenue
        }
        self.kind = kind
        self.code = normalized
    }

    private enum CodingKeys: String, CodingKey { case kind, code }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(MarketVenueKind.self, forKey: .kind),
                code: container.decode(String.self, forKey: .code)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .code,
                in: container,
                debugDescription: "Invalid market venue."
            )
        }
    }
}

/// A provider-neutral instrument identity. The UUID remains stable when the
/// user later corrects a symbol or resolves a legacy venue; provider symbols
/// are mapping metadata, never the durable holding identity.
public struct InstrumentIdentity: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: MarketInstrumentKind
    public let symbol: String
    public let venue: MarketVenue?
    public let quoteCurrency: CurrencyCode
    public let resolution: MarketInstrumentResolution

    public init(
        id: UUID = UUID(),
        kind: MarketInstrumentKind,
        symbol: String,
        venue: MarketVenue?,
        quoteCurrency: CurrencyCode,
        resolution: MarketInstrumentResolution = .resolved
    ) throws {
        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let validBytes = normalized.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (48...57).contains(byte)
                || byte == 45 || byte == 46 || byte == 47
                || byte == 58 || byte == 95
        }
        guard (1...32).contains(normalized.utf8.count), validBytes else {
            throw MarketDataModelError.invalidSymbol
        }
        guard resolution != .resolved || venue != nil else {
            throw MarketDataModelError.invalidVenue
        }
        self.id = id
        self.kind = kind
        self.symbol = normalized
        self.venue = venue
        self.quoteCurrency = quoteCurrency
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, symbol, venue, quoteCurrency, resolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                kind: container.decode(MarketInstrumentKind.self, forKey: .kind),
                symbol: container.decode(String.self, forKey: .symbol),
                venue: container.decodeIfPresent(MarketVenue.self, forKey: .venue),
                quoteCurrency: container.decode(CurrencyCode.self, forKey: .quoteCurrency),
                resolution: container.decode(
                    MarketInstrumentResolution.self,
                    forKey: .resolution
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .symbol,
                in: container,
                debugDescription: "Invalid market instrument identity."
            )
        }
    }
}

public enum MarketQuoteSourceKind: String, Codable, Hashable, Sendable {
    case manual
    case imported
    case provider
    case manualLegacy
}

public struct MarketQuoteProvenance: Codable, Equatable, Hashable, Sendable {
    public let sourceKind: MarketQuoteSourceKind
    /// Stable non-secret source identifier such as `moneyup.manual`.
    public let sourceIdentifier: String
    /// Optional opaque identifier supplied by the source for audit support.
    public let sourceRecordIdentifier: String?
    /// Optional source-native ordering for distinct events with equal source
    /// timestamps. It orders evidence without inventing a finer timestamp.
    public let sourceSequence: Int64?

    public init(
        sourceKind: MarketQuoteSourceKind,
        sourceIdentifier: String,
        sourceRecordIdentifier: String? = nil,
        sourceSequence: Int64? = nil
    ) throws {
        let identifier = try MarketDataIdentifierNormalizer.providerIdentifier(
            sourceIdentifier
        )
        let record = try sourceRecordIdentifier.map {
            try Self.normalized($0, maximumUTF8Count: 128, permitsSpaces: true)
        }
        guard sourceKind == .provider || !identifier.hasPrefix("provider.") else {
            throw MarketDataModelError.inconsistentProvenance
        }
        guard sourceSequence.map({ $0 >= 0 }) ?? true else {
            throw MarketDataModelError.invalidSource
        }
        self.sourceKind = sourceKind
        self.sourceIdentifier = identifier
        self.sourceRecordIdentifier = record
        self.sourceSequence = sourceSequence
    }

    private enum CodingKeys: String, CodingKey {
        case sourceKind, sourceIdentifier, sourceRecordIdentifier, sourceSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                sourceKind: container.decode(
                    MarketQuoteSourceKind.self,
                    forKey: .sourceKind
                ),
                sourceIdentifier: container.decode(String.self, forKey: .sourceIdentifier),
                sourceRecordIdentifier: container.decodeIfPresent(
                    String.self,
                    forKey: .sourceRecordIdentifier
                ),
                sourceSequence: container.decodeIfPresent(
                    Int64.self,
                    forKey: .sourceSequence
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceIdentifier,
                in: container,
                debugDescription: "Invalid market quote provenance."
            )
        }
    }

    private static func normalized(
        _ rawValue: String,
        maximumUTF8Count: Int,
        permitsSpaces: Bool
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Count,
              !value.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              }),
              permitsSpaces || !value.contains(where: { $0.isWhitespace }) else {
            throw MarketDataModelError.invalidSource
        }
        return value
    }
}

public enum MarketQuoteType: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case lastTrade
    case previousClose
    case endOfDay
    case netAssetValue
    case indicative
}

public enum MarketQuoteDelayKind: String, Codable, Hashable, Sendable {
    case notApplicable
    case realTime
    case delayed
    case endOfDay
    case unknown
}

public struct MarketQuoteDelay: Codable, Equatable, Hashable, Sendable {
    public let kind: MarketQuoteDelayKind
    public let seconds: Int?

    public init(kind: MarketQuoteDelayKind, seconds: Int? = nil) throws {
        switch kind {
        case .delayed:
            guard let seconds, (1...86_400).contains(seconds) else {
                throw MarketDataModelError.invalidDelay
            }
        case .notApplicable, .realTime, .endOfDay, .unknown:
            guard seconds == nil else { throw MarketDataModelError.invalidDelay }
        }
        self.kind = kind
        self.seconds = seconds
    }

    public static var notApplicable: MarketQuoteDelay {
        MarketQuoteDelay(validatedKind: .notApplicable)
    }

    public static var realTime: MarketQuoteDelay {
        MarketQuoteDelay(validatedKind: .realTime)
    }

    public static var endOfDay: MarketQuoteDelay {
        MarketQuoteDelay(validatedKind: .endOfDay)
    }

    public static var unknown: MarketQuoteDelay {
        MarketQuoteDelay(validatedKind: .unknown)
    }

    private init(validatedKind: MarketQuoteDelayKind) {
        kind = validatedKind
        seconds = nil
    }

    private enum CodingKeys: String, CodingKey { case kind, seconds }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(MarketQuoteDelayKind.self, forKey: .kind),
                seconds: container.decodeIfPresent(Int.self, forKey: .seconds)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .seconds,
                in: container,
                debugDescription: "Invalid market quote delay."
            )
        }
    }
}

public enum MarketQuoteQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case official
    case providerReported
    case indicative
    case userEntered
    case legacy
}

/// Source-reported lifecycle status. Fresh/stale is calculated separately at
/// the user's valuation instant and is never persisted as if it were timeless.
public enum MarketQuoteStatus: String, Codable, Hashable, Sendable {
    case active
    case corrected
    case preliminary
}

public enum MarketSessionState: String, Codable, Hashable, Sendable {
    case regular
    case preMarket
    case afterHours
    case closed
    case halted
    case unknown
}

/// Session facts must come from the source. MoneyUp does not infer exchange
/// holidays from a weekend-only rule, which would be wrong across venues.
public struct MarketSessionContext: Codable, Equatable, Hashable, Sendable {
    public let state: MarketSessionState
    public let nextRegularOpenAt: Date?

    public init(state: MarketSessionState, nextRegularOpenAt: Date? = nil) throws {
        guard nextRegularOpenAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            throw MarketDataModelError.invalidTimestamp
        }
        guard state == .closed || state == .halted || nextRegularOpenAt == nil else {
            throw MarketDataModelError.inconsistentSession
        }
        self.state = state
        self.nextRegularOpenAt = nextRegularOpenAt
    }

    private enum CodingKeys: String, CodingKey { case state, nextRegularOpenAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                state: container.decode(MarketSessionState.self, forKey: .state),
                nextRegularOpenAt: container.decodeIfPresent(
                    Date.self,
                    forKey: .nextRegularOpenAt
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .nextRegularOpenAt,
                in: container,
                debugDescription: "Invalid market session context."
            )
        }
    }
}

/// Immutable valuation evidence. It is intentionally separate from
/// `InvestmentHolding.priceHistory`: receiving a quote never posts a journal
/// entry or silently changes the holding's recorded value.
public struct MarketQuoteObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let instrumentID: UUID
    public let unitPrice: Money
    public let marketTimestamp: Date
    public let receivedAt: Date
    public let quoteType: MarketQuoteType
    public let delay: MarketQuoteDelay
    public let status: MarketQuoteStatus
    public let quality: MarketQuoteQuality
    public let session: MarketSessionContext
    public let provenance: MarketQuoteProvenance

    public init(
        id: UUID = UUID(),
        instrument: InstrumentIdentity,
        unitPrice: Money,
        marketTimestamp: Date,
        receivedAt: Date,
        quoteType: MarketQuoteType,
        delay: MarketQuoteDelay,
        status: MarketQuoteStatus = .active,
        quality: MarketQuoteQuality,
        session: MarketSessionContext,
        provenance: MarketQuoteProvenance
    ) throws {
        guard unitPrice.amount >= .zero, !unitPrice.amount.isNaN else {
            throw MarketDataModelError.invalidPrice
        }
        let isExplicitManualWriteDown = unitPrice.amount == .zero
            && quoteType == .manual
            && (provenance.sourceKind == .manual
                || provenance.sourceKind == .manualLegacy)
        guard unitPrice.amount > .zero || isExplicitManualWriteDown else {
            throw MarketDataModelError.invalidPrice
        }
        guard unitPrice.currency == instrument.quoteCurrency else {
            throw MarketDataModelError.currencyMismatch
        }
        guard marketTimestamp.timeIntervalSinceReferenceDate.isFinite,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              marketTimestamp <= receivedAt,
              session.nextRegularOpenAt.map({ $0 > marketTimestamp }) ?? true else {
            throw MarketDataModelError.invalidTimestamp
        }
        try Self.validateSemantics(
            quoteType: quoteType,
            delay: delay,
            status: status,
            quality: quality,
            provenance: provenance
        )
        self.id = id
        instrumentID = instrument.id
        self.unitPrice = unitPrice
        self.marketTimestamp = marketTimestamp
        self.receivedAt = receivedAt
        self.quoteType = quoteType
        self.delay = delay
        self.status = status
        self.quality = quality
        self.session = session
        self.provenance = provenance
    }

    public var dedupeKey: MarketQuoteDedupeKey {
        MarketQuoteDedupeKey(
            instrumentID: instrumentID,
            sourceKind: provenance.sourceKind,
            sourceIdentifier: provenance.sourceIdentifier,
            sourceRecordIdentifier: provenance.sourceRecordIdentifier,
            sourceSequence: provenance.sourceSequence,
            marketTimestamp: marketTimestamp,
            quoteType: quoteType
        )
    }

    private static func validateSemantics(
        quoteType: MarketQuoteType,
        delay: MarketQuoteDelay,
        status: MarketQuoteStatus,
        quality: MarketQuoteQuality,
        provenance: MarketQuoteProvenance
    ) throws {
        switch provenance.sourceKind {
        case .manual:
            guard quoteType == .manual,
                  delay.kind == .notApplicable,
                  quality == .userEntered else {
                throw MarketDataModelError.inconsistentProvenance
            }
        case .manualLegacy:
            guard quoteType == .manual,
                  delay.kind == .notApplicable,
                  quality == .legacy else {
                throw MarketDataModelError.inconsistentProvenance
            }
        case .provider:
            guard quoteType != .manual,
                  quality != .userEntered,
                  quality != .legacy else {
                throw MarketDataModelError.inconsistentProvenance
            }
        case .imported:
            break
        }
        if quoteType == .manual {
            guard delay.kind == .notApplicable,
                  quality == .userEntered || quality == .legacy,
                  provenance.sourceKind != .provider else {
                throw MarketDataModelError.inconsistentProvenance
            }
        }
        if status == .preliminary, quality != .indicative {
            throw MarketDataModelError.inconsistentProvenance
        }
        if delay.kind == .endOfDay,
           quoteType != .endOfDay && quoteType != .previousClose {
            throw MarketDataModelError.invalidDelay
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, instrumentID, unitPrice, marketTimestamp, receivedAt
        case quoteType, delay, status, quality, session, provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let instrumentID = try container.decode(UUID.self, forKey: .instrumentID)
        let price = try container.decode(Money.self, forKey: .unitPrice)
        let syntheticInstrument = try InstrumentIdentity(
            id: instrumentID,
            kind: .other,
            symbol: "DECODED",
            venue: nil,
            quoteCurrency: price.currency,
            resolution: .manualLegacy
        )
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                instrument: syntheticInstrument,
                unitPrice: price,
                marketTimestamp: container.decode(Date.self, forKey: .marketTimestamp),
                receivedAt: container.decode(Date.self, forKey: .receivedAt),
                quoteType: container.decode(MarketQuoteType.self, forKey: .quoteType),
                delay: container.decode(MarketQuoteDelay.self, forKey: .delay),
                status: container.decode(MarketQuoteStatus.self, forKey: .status),
                quality: container.decode(MarketQuoteQuality.self, forKey: .quality),
                session: container.decode(MarketSessionContext.self, forKey: .session),
                provenance: container.decode(
                    MarketQuoteProvenance.self,
                    forKey: .provenance
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .unitPrice,
                in: container,
                debugDescription: "Invalid market quote observation."
            )
        }
    }
}

public struct MarketQuoteDedupeKey: Equatable, Hashable, Sendable {
    public let instrumentID: UUID
    public let sourceKind: MarketQuoteSourceKind
    public let sourceIdentifier: String
    public let sourceRecordIdentifier: String?
    public let sourceSequence: Int64?
    public let marketTimestamp: Date
    /// When a source supplies no native record or sequence identity, retain the
    /// quote type as a conservative fallback so unrelated same-time evidence is
    /// not collapsed. Identified events may change type in a later correction.
    public let fallbackQuoteType: MarketQuoteType?

    public init(
        instrumentID: UUID,
        sourceKind: MarketQuoteSourceKind,
        sourceIdentifier: String,
        sourceRecordIdentifier: String?,
        sourceSequence: Int64?,
        marketTimestamp: Date,
        quoteType: MarketQuoteType
    ) {
        self.instrumentID = instrumentID
        self.sourceKind = sourceKind
        self.sourceIdentifier = sourceIdentifier
        self.sourceRecordIdentifier = sourceRecordIdentifier
        self.sourceSequence = sourceSequence
        self.marketTimestamp = marketTimestamp
        fallbackQuoteType = sourceRecordIdentifier == nil && sourceSequence == nil
            ? quoteType : nil
    }
}
