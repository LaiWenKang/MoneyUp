import Foundation

public enum MarketDataAccessMode: String, Codable, Sendable {
    case manualOnly
    /// Future adapters may run only from an authenticated foreground action.
    case foregroundOnDemand
}

public enum MarketStaleQuoteUsage: String, Codable, Sendable {
    /// Preserve the last observation and label it stale; never substitute zero.
    case retainWithWarning
    /// Leave the recorded ledger value unchanged when no fresh quote exists.
    case reject
}

public enum MarketDataPolicyError: Error, Equatable, Sendable {
    case invalidFreshnessWindow
    case invalidProviderConfiguration
}

public struct MarketDataPolicy: Codable, Equatable, Sendable {
    public let accessMode: MarketDataAccessMode
    public let approvedProviderIdentifier: String?
    public let maximumAgeSeconds: Int
    public let permitsDelayedQuotes: Bool
    public let permitsEndOfDayQuotes: Bool
    public let permitsIndicativeQuotes: Bool
    public let staleQuoteUsage: MarketStaleQuoteUsage

    public init(
        accessMode: MarketDataAccessMode,
        approvedProviderIdentifier: String?,
        maximumAgeSeconds: Int = 7 * 86_400,
        permitsDelayedQuotes: Bool = true,
        permitsEndOfDayQuotes: Bool = true,
        permitsIndicativeQuotes: Bool = false,
        staleQuoteUsage: MarketStaleQuoteUsage = .retainWithWarning
    ) throws {
        guard (60...31_536_000).contains(maximumAgeSeconds) else {
            throw MarketDataPolicyError.invalidFreshnessWindow
        }
        let normalizedProvider: String?
        do {
            normalizedProvider = try approvedProviderIdentifier.map {
                try MarketDataIdentifierNormalizer.providerIdentifier($0)
            }
        } catch {
            throw MarketDataPolicyError.invalidProviderConfiguration
        }
        switch accessMode {
        case .manualOnly:
            guard approvedProviderIdentifier == nil else {
                throw MarketDataPolicyError.invalidProviderConfiguration
            }
        case .foregroundOnDemand:
            guard normalizedProvider != nil else {
                throw MarketDataPolicyError.invalidProviderConfiguration
            }
        }
        self.accessMode = accessMode
        self.approvedProviderIdentifier = normalizedProvider
        self.maximumAgeSeconds = maximumAgeSeconds
        self.permitsDelayedQuotes = permitsDelayedQuotes
        self.permitsEndOfDayQuotes = permitsEndOfDayQuotes
        self.permitsIndicativeQuotes = permitsIndicativeQuotes
        self.staleQuoteUsage = staleQuoteUsage
    }

    public static var manualLocalDefault: MarketDataPolicy {
        MarketDataPolicy(
            validatedAccessMode: .manualOnly,
            approvedProviderIdentifier: nil,
            maximumAgeSeconds: 7 * 86_400,
            permitsDelayedQuotes: true,
            permitsEndOfDayQuotes: true,
            permitsIndicativeQuotes: false,
            staleQuoteUsage: .retainWithWarning
        )
    }

    private init(
        validatedAccessMode: MarketDataAccessMode,
        approvedProviderIdentifier: String?,
        maximumAgeSeconds: Int,
        permitsDelayedQuotes: Bool,
        permitsEndOfDayQuotes: Bool,
        permitsIndicativeQuotes: Bool,
        staleQuoteUsage: MarketStaleQuoteUsage
    ) {
        accessMode = validatedAccessMode
        self.approvedProviderIdentifier = approvedProviderIdentifier
        self.maximumAgeSeconds = maximumAgeSeconds
        self.permitsDelayedQuotes = permitsDelayedQuotes
        self.permitsEndOfDayQuotes = permitsEndOfDayQuotes
        self.permitsIndicativeQuotes = permitsIndicativeQuotes
        self.staleQuoteUsage = staleQuoteUsage
    }

    private enum CodingKeys: String, CodingKey {
        case accessMode, approvedProviderIdentifier, maximumAgeSeconds
        case permitsDelayedQuotes, permitsEndOfDayQuotes, permitsIndicativeQuotes
        case staleQuoteUsage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                accessMode: container.decode(MarketDataAccessMode.self, forKey: .accessMode),
                approvedProviderIdentifier: container.decodeIfPresent(
                    String.self,
                    forKey: .approvedProviderIdentifier
                ),
                maximumAgeSeconds: container.decode(Int.self, forKey: .maximumAgeSeconds),
                permitsDelayedQuotes: container.decode(
                    Bool.self,
                    forKey: .permitsDelayedQuotes
                ),
                permitsEndOfDayQuotes: container.decode(
                    Bool.self,
                    forKey: .permitsEndOfDayQuotes
                ),
                permitsIndicativeQuotes: container.decode(
                    Bool.self,
                    forKey: .permitsIndicativeQuotes
                ),
                staleQuoteUsage: container.decode(
                    MarketStaleQuoteUsage.self,
                    forKey: .staleQuoteUsage
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .accessMode,
                in: container,
                debugDescription: "Invalid market data policy."
            )
        }
    }
}

public enum MarketQuoteFreshness: Equatable, Sendable {
    case current
    case closedSessionCarryForward(nextRegularOpenAt: Date)
    case stale
}

public enum MarketQuoteSelectionFailure: String, Equatable, Sendable {
    case noObservation
    case observationNotYetAvailable
    case quoteCurrencyMismatch
    case sourceNotAllowed
    case quoteTypeNotAllowed
    case staleRejected
}

public struct MarketQuoteAssessment: Equatable, Sendable {
    public let observation: MarketQuoteObservation
    public let freshness: MarketQuoteFreshness

    public init(observation: MarketQuoteObservation, freshness: MarketQuoteFreshness) {
        self.observation = observation
        self.freshness = freshness
    }
}

public enum MarketQuoteResolution: Equatable, Sendable {
    case selected(MarketQuoteAssessment)
    case unavailable(MarketQuoteSelectionFailure)
}

public enum MarketQuoteResolver {
    public static func latest(
        for instrument: InstrumentIdentity,
        observations: [MarketQuoteObservation],
        at valuationDate: Date,
        policy: MarketDataPolicy = .manualLocalDefault
    ) -> MarketQuoteResolution {
        guard valuationDate.timeIntervalSinceReferenceDate.isFinite else {
            return .unavailable(.observationNotYetAvailable)
        }
        let matching = observations.filter { $0.instrumentID == instrument.id }
        guard !matching.isEmpty else { return .unavailable(.noObservation) }
        let available = matching.filter {
            $0.marketTimestamp <= valuationDate && $0.receivedAt <= valuationDate
        }
        guard !available.isEmpty else {
            return .unavailable(.observationNotYetAvailable)
        }
        // Resolve immutable event identity before applying mutable correction
        // attributes. Otherwise an older allowed version can be resurrected
        // when its newest correction becomes ineligible under current policy.
        let deduplicated = deduplicate(available)
        let currencyEligible = deduplicated.filter {
            $0.unitPrice.currency == instrument.quoteCurrency
        }
        guard !currencyEligible.isEmpty else {
            return .unavailable(.quoteCurrencyMismatch)
        }
        let sourceEligible = currencyEligible.filter {
            sourceIsAllowed($0, policy: policy)
        }
        guard !sourceEligible.isEmpty else {
            return .unavailable(.sourceNotAllowed)
        }
        let typeEligible = sourceEligible.filter { quoteTypeIsAllowed($0, policy: policy) }
        guard !typeEligible.isEmpty else {
            return .unavailable(.quoteTypeNotAllowed)
        }
        guard let selected = typeEligible.max(by: quoteOrder) else {
            return .unavailable(.noObservation)
        }
        let freshness = freshness(of: selected, at: valuationDate, policy: policy)
        if freshness == .stale, policy.staleQuoteUsage == .reject {
            return .unavailable(.staleRejected)
        }
        return .selected(MarketQuoteAssessment(
            observation: selected,
            freshness: freshness
        ))
    }

    public static func deduplicate(
        _ observations: [MarketQuoteObservation]
    ) -> [MarketQuoteObservation] {
        var selected: [MarketQuoteDedupeKey: MarketQuoteObservation] = [:]
        for observation in observations {
            guard let existing = selected[observation.dedupeKey] else {
                selected[observation.dedupeKey] = observation
                continue
            }
            if correctionOrder(existing, observation) {
                selected[observation.dedupeKey] = observation
            }
        }
        return selected.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func sourceIsAllowed(
        _ observation: MarketQuoteObservation,
        policy: MarketDataPolicy
    ) -> Bool {
        switch observation.provenance.sourceKind {
        case .manual, .imported, .manualLegacy:
            return true
        case .provider:
            return policy.accessMode == .foregroundOnDemand
                && observation.provenance.sourceIdentifier
                    == policy.approvedProviderIdentifier
        }
    }

    private static func quoteTypeIsAllowed(
        _ observation: MarketQuoteObservation,
        policy: MarketDataPolicy
    ) -> Bool {
        if observation.quoteType == .indicative || observation.quality == .indicative {
            return policy.permitsIndicativeQuotes
        }
        if observation.delay.kind == .delayed, !policy.permitsDelayedQuotes {
            return false
        }
        if observation.quoteType == .endOfDay
            || observation.quoteType == .previousClose
            || observation.delay.kind == .endOfDay {
            return policy.permitsEndOfDayQuotes
        }
        return true
    }

    private static func freshness(
        of observation: MarketQuoteObservation,
        at valuationDate: Date,
        policy: MarketDataPolicy
    ) -> MarketQuoteFreshness {
        if let nextOpen = observation.session.nextRegularOpenAt {
            if valuationDate < nextOpen {
                return .closedSessionCarryForward(nextRegularOpenAt: nextOpen)
            }
            return .stale
        }
        let age = valuationDate.timeIntervalSince(observation.marketTimestamp)
        if age <= TimeInterval(policy.maximumAgeSeconds) { return .current }
        return .stale
    }

    private static func correctionOrder(
        _ left: MarketQuoteObservation,
        _ right: MarketQuoteObservation
    ) -> Bool {
        if left.receivedAt != right.receivedAt {
            return left.receivedAt < right.receivedAt
        }
        if let ordered = sourceSequenceOrder(left, right) { return ordered }
        if statusRank(left.status) != statusRank(right.status) {
            return statusRank(left.status) < statusRank(right.status)
        }
        if qualityRank(left.quality) != qualityRank(right.quality) {
            return qualityRank(left.quality) < qualityRank(right.quality)
        }
        return left.id.uuidString < right.id.uuidString
    }

    private static func quoteOrder(
        _ left: MarketQuoteObservation,
        _ right: MarketQuoteObservation
    ) -> Bool {
        if left.marketTimestamp != right.marketTimestamp {
            return left.marketTimestamp < right.marketTimestamp
        }
        if left.receivedAt != right.receivedAt {
            return left.receivedAt < right.receivedAt
        }
        if let ordered = sourceSequenceOrder(left, right) { return ordered }
        if statusRank(left.status) != statusRank(right.status) {
            return statusRank(left.status) < statusRank(right.status)
        }
        if qualityRank(left.quality) != qualityRank(right.quality) {
            return qualityRank(left.quality) < qualityRank(right.quality)
        }
        return left.id.uuidString < right.id.uuidString
    }

    private static func sourceSequenceOrder(
        _ left: MarketQuoteObservation,
        _ right: MarketQuoteObservation
    ) -> Bool? {
        guard left.provenance.sourceKind == right.provenance.sourceKind,
              left.provenance.sourceIdentifier
                == right.provenance.sourceIdentifier,
              let leftSequence = left.provenance.sourceSequence,
              let rightSequence = right.provenance.sourceSequence,
              leftSequence != rightSequence else {
            return nil
        }
        return leftSequence < rightSequence
    }

    private static func qualityRank(_ quality: MarketQuoteQuality) -> Int {
        switch quality {
        case .legacy: 0
        case .indicative: 1
        case .userEntered: 2
        case .providerReported: 3
        case .official: 4
        }
    }

    private static func statusRank(_ status: MarketQuoteStatus) -> Int {
        switch status {
        case .preliminary: 0
        case .active: 1
        case .corrected: 2
        }
    }
}

public enum MarketQuoteUnavailableReason: String, Equatable, Sendable {
    case notConfigured
    case consentRequired
    case ambiguousIdentity
    case unsupportedInstrument
    case notEntitled
    case throttled
    case marketUnavailable
    case noData
    case providerFailure
    case invalidResponse
}

public enum MarketQuoteOutcome: Equatable, Sendable {
    case observation(MarketQuoteObservation)
    case unavailable(MarketQuoteUnavailableReason)
}

public enum MarketQuoteBatchError: Error, Equatable, Sendable {
    case emptyRequest
    case duplicateInstrument
    case resultSetMismatch
    case observationMismatch
    case invalidTimestamp
    case requestMismatch
    case sourceMismatch
}

public struct MarketQuoteResult: Equatable, Sendable {
    public let instrumentID: UUID
    public let outcome: MarketQuoteOutcome

    public init(instrumentID: UUID, outcome: MarketQuoteOutcome) throws {
        if case let .observation(observation) = outcome,
           observation.instrumentID != instrumentID {
            throw MarketQuoteBatchError.observationMismatch
        }
        self.instrumentID = instrumentID
        self.outcome = outcome
    }
}

public enum MarketQuoteBatchCompleteness: String, Equatable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct MarketQuoteBatch: Equatable, Sendable {
    public let requestID: UUID
    public let requestedAt: Date
    public let completedAt: Date
    public let results: [MarketQuoteResult]

    public init(
        requestID: UUID,
        requestedInstrumentIDs: [UUID],
        requestedAt: Date,
        completedAt: Date,
        results: [MarketQuoteResult]
    ) throws {
        guard !requestedInstrumentIDs.isEmpty,
              requestedInstrumentIDs.count <= MarketQuoteRequest.maximumInstrumentCount else {
            throw MarketQuoteBatchError.emptyRequest
        }
        guard Set(requestedInstrumentIDs).count == requestedInstrumentIDs.count,
              Set(results.map(\.instrumentID)).count == results.count else {
            throw MarketQuoteBatchError.duplicateInstrument
        }
        guard Set(requestedInstrumentIDs) == Set(results.map(\.instrumentID)) else {
            throw MarketQuoteBatchError.resultSetMismatch
        }
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              requestedAt <= completedAt else {
            throw MarketQuoteBatchError.invalidTimestamp
        }
        let observationsAreAvailable = results.allSatisfy { result in
            if case let .observation(observation) = result.outcome {
                return observation.receivedAt <= completedAt
            }
            return true
        }
        guard observationsAreAvailable else {
            throw MarketQuoteBatchError.invalidTimestamp
        }
        self.requestID = requestID
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.results = results.sorted {
            $0.instrumentID.uuidString < $1.instrumentID.uuidString
        }
    }

    public var completeness: MarketQuoteBatchCompleteness {
        let availableCount = results.reduce(into: 0) { count, result in
            if case .observation = result.outcome { count += 1 }
        }
        if availableCount == results.count { return .complete }
        if availableCount == 0 { return .unavailable }
        return .partial
    }

    /// Only valid observations are returned for persistence. Unavailable
    /// outcomes remain explicit diagnostics and can never become zero prices.
    public var observations: [MarketQuoteObservation] {
        results.compactMap { result in
            if case let .observation(observation) = result.outcome {
                return observation
            }
            return nil
        }
    }
}

public enum MarketQuoteRequestReason: String, Equatable, Sendable {
    case userInitiated
    case assetsForeground
}

public struct MarketQuoteRequest: Equatable, Sendable {
    public static let maximumInstrumentCount = 100
    public let id: UUID
    public let instruments: [InstrumentIdentity]
    public let requestedAt: Date
    public let reason: MarketQuoteRequestReason

    public init(
        id: UUID = UUID(),
        instruments: [InstrumentIdentity],
        requestedAt: Date,
        reason: MarketQuoteRequestReason
    ) throws {
        guard !instruments.isEmpty,
              instruments.count <= Self.maximumInstrumentCount else {
            throw MarketQuoteBatchError.emptyRequest
        }
        guard Set(instruments.map(\.id)).count == instruments.count else {
            throw MarketQuoteBatchError.duplicateInstrument
        }
        guard instruments.allSatisfy({ $0.resolution == .resolved }) else {
            throw MarketQuoteBatchError.resultSetMismatch
        }
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MarketQuoteBatchError.invalidTimestamp
        }
        self.id = id
        self.instruments = instruments.sorted { $0.id.uuidString < $1.id.uuidString }
        self.requestedAt = requestedAt
        self.reason = reason
    }
}

public struct MarketDataProviderDescriptor: Equatable, Sendable {
    public let identifier: String
    public let supportedKinds: Set<MarketInstrumentKind>

    public init(identifier: String, supportedKinds: Set<MarketInstrumentKind>) throws {
        let normalized = try MarketDataIdentifierNormalizer.providerIdentifier(identifier)
        guard !supportedKinds.isEmpty else {
            throw MarketDataModelError.invalidIdentifier
        }
        self.identifier = normalized
        self.supportedKinds = supportedKinds
    }
}

/// Treats an adapter response as untrusted until it is bound back to the exact
/// request and provider capability that produced it. This prevents an adapter
/// from laundering imported/manual evidence through the provider path.
public enum MarketQuoteProviderResponseValidator {
    public static func validated(
        _ batch: MarketQuoteBatch,
        for request: MarketQuoteRequest,
        provider: MarketDataProviderDescriptor
    ) throws -> MarketQuoteBatch {
        let requestedIDs = Set(request.instruments.map(\.id))
        let requestedQuoteCurrencies = Dictionary(
            uniqueKeysWithValues: request.instruments.map { ($0.id, $0.quoteCurrency) }
        )
        let resultIDs = Set(batch.results.map(\.instrumentID))
        let observationCurrenciesMatch = batch.observations.allSatisfy { observation in
            requestedQuoteCurrencies[observation.instrumentID] == observation.unitPrice.currency
        }
        guard batch.requestID == request.id,
              batch.requestedAt == request.requestedAt,
              requestedIDs == resultIDs,
              observationCurrenciesMatch,
              request.instruments.allSatisfy({
                  provider.supportedKinds.contains($0.kind)
              }) else {
            throw MarketQuoteBatchError.requestMismatch
        }
        let sourcesMatch = batch.observations.allSatisfy { observation in
            observation.provenance.sourceKind == .provider
                && observation.provenance.sourceIdentifier == provider.identifier
        }
        guard sourcesMatch else { throw MarketQuoteBatchError.sourceMismatch }
        return batch
    }
}

/// Capability boundary only. MoneyUpCore contains no transport, endpoint,
/// credential, scheduler, or concrete provider implementation.
public protocol MarketDataProvider: Sendable {
    var descriptor: MarketDataProviderDescriptor { get }
    /// Raw adapter seam. Consumers use `validatedQuotes(for:)` so source and
    /// request provenance are checked before observations can be persisted.
    func quotes(for request: MarketQuoteRequest) async throws -> MarketQuoteBatch
}

public extension MarketDataProvider {
    func validatedQuotes(
        for request: MarketQuoteRequest
    ) async throws -> MarketQuoteBatch {
        let batch = try await quotes(for: request)
        return try MarketQuoteProviderResponseValidator.validated(
            batch,
            for: request,
            provider: descriptor
        )
    }
}

public enum MarketDataRequestDecision: Equatable, Sendable {
    case localOnly
    case foreground(MarketQuoteRequest)
}

public enum MarketDataRequestPlanner {
    public static func decision(
        instruments: [InstrumentIdentity],
        provider: MarketDataProviderDescriptor,
        policy: MarketDataPolicy,
        requestedAt: Date,
        reason: MarketQuoteRequestReason
    ) throws -> MarketDataRequestDecision {
        guard policy.accessMode == .foregroundOnDemand,
              policy.approvedProviderIdentifier == provider.identifier else {
            return .localOnly
        }
        let supported = instruments.filter {
            $0.resolution == .resolved && provider.supportedKinds.contains($0.kind)
        }
        guard !supported.isEmpty else { return .localOnly }
        return .foreground(try MarketQuoteRequest(
            instruments: supported,
            requestedAt: requestedAt,
            reason: reason
        ))
    }
}

public struct MarketQuoteAppendResult: Equatable, Sendable {
    public let insertedIDs: [UUID]
    public let duplicateIDs: [UUID]

    public init(insertedIDs: [UUID], duplicateIDs: [UUID]) {
        self.insertedIDs = insertedIDs.sorted { $0.uuidString < $1.uuidString }
        self.duplicateIDs = duplicateIDs.sorted { $0.uuidString < $1.uuidString }
    }
}

/// Persistence boundary for a future encrypted implementation. Stores append
/// immutable observations by dedupe key; it must not write HoldingPricePoint or
/// JournalEntry records as a side effect.
public protocol MarketQuoteObservationStore: Sendable {
    func append(
        _ observations: [MarketQuoteObservation]
    ) async throws -> MarketQuoteAppendResult

    func observations(
        for instrumentID: UUID,
        notAfter date: Date,
        limit: Int
    ) async throws -> [MarketQuoteObservation]
}
