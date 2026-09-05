import Foundation
@testable import MoneyUpCore
import XCTest

final class MarketDataFoundationTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testInstrumentIdentityNormalizesMetadataAndRoundTripsStableID() throws {
        let id = UUID()
        let usd = try CurrencyCode("USD")
        let instrument = try InstrumentIdentity(
            id: id,
            kind: .equity,
            symbol: " mu ",
            venue: try MarketVenue(kind: .mic, code: "xnas"),
            quoteCurrency: usd
        )

        let restored = try JSONDecoder().decode(
            InstrumentIdentity.self,
            from: JSONEncoder().encode(instrument)
        )

        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.symbol, "MU")
        XCTAssertEqual(restored.venue?.code, "XNAS")
        XCTAssertEqual(restored, instrument)
    }

    func testQuoteObservationPreservesExactDecimalAndProvenance() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let exact = try XCTUnwrap(
            Decimal(string: "123.456789123456789", locale: posix)
        )
        let observation = try makeManualQuote(
            instrument: instrument,
            amount: exact,
            marketTimestamp: instant
        )

        let restored = try JSONDecoder().decode(
            MarketQuoteObservation.self,
            from: JSONEncoder().encode(observation)
        )

        XCTAssertEqual(restored.unitPrice.amount, exact)
        XCTAssertEqual(restored.unitPrice.currency, instrument.quoteCurrency)
        XCTAssertEqual(restored.provenance.sourceIdentifier, "moneyup.manual")
        XCTAssertEqual(restored, observation)
    }

    func testObservationRejectsWrongQuoteCurrencyAndImpossibleTimeOrder() throws {
        let instrument = try makeInstrument()
        let sgd = try CurrencyCode("SGD")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provenance = try MarketQuoteProvenance(
            sourceKind: .manual,
            sourceIdentifier: "moneyup.manual"
        )

        XCTAssertThrowsError(try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(10, currency: sgd),
            marketTimestamp: now,
            receivedAt: now,
            quoteType: .manual,
            delay: .notApplicable,
            quality: .userEntered,
            session: try MarketSessionContext(state: .unknown),
            provenance: provenance
        )) { error in
            XCTAssertEqual(error as? MarketDataModelError, .currencyMismatch)
        }

        XCTAssertThrowsError(try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(10, currency: instrument.quoteCurrency),
            marketTimestamp: now,
            receivedAt: now.addingTimeInterval(-1),
            quoteType: .manual,
            delay: .notApplicable,
            quality: .userEntered,
            session: try MarketSessionContext(state: .unknown),
            provenance: provenance
        )) { error in
            XCTAssertEqual(error as? MarketDataModelError, .invalidTimestamp)
        }
    }

    func testManualSourceCannotMasqueradeAsProviderQuote() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertThrowsError(try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(10, currency: instrument.quoteCurrency),
            marketTimestamp: instant,
            receivedAt: instant,
            quoteType: .lastTrade,
            delay: .realTime,
            quality: .official,
            session: try MarketSessionContext(state: .regular),
            provenance: try MarketQuoteProvenance(
                sourceKind: .manual,
                sourceIdentifier: "moneyup.manual"
            )
        )) { error in
            XCTAssertEqual(
                error as? MarketDataModelError,
                .inconsistentProvenance
            )
        }
    }

    func testManualAndLegacySourcesRequireTheirExactEvidenceClass() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)

        for provenance in [
            try MarketQuoteProvenance(
                sourceKind: .manual,
                sourceIdentifier: "moneyup.manual"
            ),
            try MarketQuoteProvenance(
                sourceKind: .manualLegacy,
                sourceIdentifier: "moneyup.legacy"
            )
        ] {
            XCTAssertThrowsError(try MarketQuoteObservation(
                instrument: instrument,
                unitPrice: try Money(10, currency: instrument.quoteCurrency),
                marketTimestamp: instant,
                receivedAt: instant,
                quoteType: .manual,
                delay: .notApplicable,
                quality: provenance.sourceKind == .manual ? .legacy : .userEntered,
                session: try MarketSessionContext(state: .unknown),
                provenance: provenance
            )) { error in
                XCTAssertEqual(
                    error as? MarketDataModelError,
                    .inconsistentProvenance
                )
            }
        }
    }

    func testProviderSourceCannotCarryUserOrLegacyQuality() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let provenance = try MarketQuoteProvenance(
            sourceKind: .provider,
            sourceIdentifier: "provider.example"
        )

        for quality in [MarketQuoteQuality.userEntered, .legacy] {
            XCTAssertThrowsError(try MarketQuoteObservation(
                instrument: instrument,
                unitPrice: try Money(10, currency: instrument.quoteCurrency),
                marketTimestamp: instant,
                receivedAt: instant,
                quoteType: .lastTrade,
                delay: .realTime,
                quality: quality,
                session: try MarketSessionContext(state: .regular),
                provenance: provenance
            )) { error in
                XCTAssertEqual(
                    error as? MarketDataModelError,
                    .inconsistentProvenance
                )
            }
        }
    }

    func testManualDefaultBlocksProviderRequestPlanning() throws {
        let instrument = try makeInstrument()
        let descriptor = try MarketDataProviderDescriptor(
            identifier: "provider.example",
            supportedKinds: [.equity]
        )

        let decision = try MarketDataRequestPlanner.decision(
            instruments: [instrument],
            provider: descriptor,
            policy: .manualLocalDefault,
            requestedAt: Date(timeIntervalSince1970: 1_800_000_000),
            reason: .userInitiated
        )

        XCTAssertEqual(decision, .localOnly)
    }

    func testExplicitForegroundPolicyPlansOnlyResolvedSupportedInstruments() throws {
        let resolved = try makeInstrument()
        let legacy = try InstrumentIdentity(
            id: UUID(),
            kind: .equity,
            symbol: "D05",
            venue: nil,
            quoteCurrency: try CurrencyCode("SGD"),
            resolution: .manualLegacy
        )
        let descriptor = try MarketDataProviderDescriptor(
            identifier: "provider.example",
            supportedKinds: [.equity]
        )
        let policy = try providerPolicy(identifier: descriptor.identifier)

        let decision = try MarketDataRequestPlanner.decision(
            instruments: [legacy, resolved],
            provider: descriptor,
            policy: policy,
            requestedAt: Date(timeIntervalSince1970: 1_800_000_000),
            reason: .assetsForeground
        )

        guard case let .foreground(request) = decision else {
            return XCTFail("Expected an explicitly approved foreground request.")
        }
        XCTAssertEqual(request.instruments.map(\.id), [resolved.id])
        XCTAssertEqual(request.reason, .assetsForeground)
    }

    func testDedupeUsesLatestReceivedCorrectionIndependentOfInputOrder() throws {
        let instrument = try makeInstrument()
        let marketTime = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeProviderQuote(
            instrument: instrument,
            amount: 100,
            marketTimestamp: marketTime,
            receivedAt: marketTime.addingTimeInterval(10),
            sourceRecordIdentifier: "trade-1"
        )
        let correction = try makeProviderQuote(
            instrument: instrument,
            amount: 101,
            marketTimestamp: marketTime,
            receivedAt: marketTime.addingTimeInterval(20),
            sourceRecordIdentifier: "trade-1"
        )
        let policy = try providerPolicy(identifier: "provider.example")

        let left = MarketQuoteResolver.latest(
            for: instrument,
            observations: [first, correction],
            at: marketTime.addingTimeInterval(30),
            policy: policy
        )
        let right = MarketQuoteResolver.latest(
            for: instrument,
            observations: [correction, first],
            at: marketTime.addingTimeInterval(30),
            policy: policy
        )

        XCTAssertEqual(selectedObservation(left)?.unitPrice.amount, 101)
        XCTAssertEqual(selectedObservation(right)?.id, selectedObservation(left)?.id)
    }

    func testDedupePreservesDistinctEqualTimeSequencesAndSourceKinds() throws {
        let instrument = try makeInstrument()
        let marketTime = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeProviderQuote(
            instrument: instrument,
            amount: 100,
            marketTimestamp: marketTime,
            receivedAt: marketTime,
            sourceRecordIdentifier: "trade",
            sourceSequence: 1
        )
        let second = try makeProviderQuote(
            instrument: instrument,
            amount: 101,
            marketTimestamp: marketTime,
            receivedAt: marketTime,
            sourceRecordIdentifier: "trade",
            sourceSequence: 2
        )
        let providerFromSharedSource = try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(102, currency: instrument.quoteCurrency),
            marketTimestamp: marketTime,
            receivedAt: marketTime,
            quoteType: .lastTrade,
            delay: .realTime,
            quality: .providerReported,
            session: try MarketSessionContext(state: .regular),
            provenance: try MarketQuoteProvenance(
                sourceKind: .provider,
                sourceIdentifier: "moneyup.shared",
                sourceRecordIdentifier: "shared-trade",
                sourceSequence: 1
            )
        )
        let imported = try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(103, currency: instrument.quoteCurrency),
            marketTimestamp: marketTime,
            receivedAt: marketTime,
            quoteType: .lastTrade,
            delay: .realTime,
            quality: .providerReported,
            session: try MarketSessionContext(state: .regular),
            provenance: try MarketQuoteProvenance(
                sourceKind: .imported,
                sourceIdentifier: "moneyup.shared",
                sourceRecordIdentifier: "shared-trade",
                sourceSequence: 1
            )
        )

        let deduplicated = MarketQuoteResolver.deduplicate([
            first, second, providerFromSharedSource, imported
        ])

        XCTAssertEqual(Set(deduplicated.map(\.id)), Set([
            first.id, second.id, providerFromSharedSource.id, imported.id
        ]))
    }

    func testNewestCorrectionCannotResurrectOlderPolicyEligibleEvidence() throws {
        let instrument = try makeInstrument()
        let marketTime = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(100, currency: instrument.quoteCurrency),
            marketTimestamp: marketTime,
            receivedAt: marketTime.addingTimeInterval(10),
            quoteType: .lastTrade,
            delay: .realTime,
            quality: .providerReported,
            session: try MarketSessionContext(state: .regular),
            provenance: try MarketQuoteProvenance(
                sourceKind: .provider,
                sourceIdentifier: "provider.example",
                sourceRecordIdentifier: "trade-1"
            )
        )
        let correction = try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(101, currency: instrument.quoteCurrency),
            marketTimestamp: marketTime,
            receivedAt: marketTime.addingTimeInterval(20),
            quoteType: .lastTrade,
            delay: try MarketQuoteDelay(kind: .delayed, seconds: 900),
            quality: .providerReported,
            session: try MarketSessionContext(state: .regular),
            provenance: try MarketQuoteProvenance(
                sourceKind: .provider,
                sourceIdentifier: "provider.example",
                sourceRecordIdentifier: "trade-1"
            )
        )
        let policy = try MarketDataPolicy(
            accessMode: .foregroundOnDemand,
            approvedProviderIdentifier: "provider.example",
            permitsDelayedQuotes: false
        )

        let resolution = MarketQuoteResolver.latest(
            for: instrument,
            observations: [first, correction],
            at: marketTime.addingTimeInterval(30),
            policy: policy
        )

        XCTAssertEqual(resolution, .unavailable(.quoteTypeNotAllowed))
    }

    func testWeekendEndOfDayQuoteCarriesOnlyUntilSuppliedNextSessionOpen() throws {
        let instrument = try makeInstrument()
        let fridayClose = Date(timeIntervalSince1970: 1_800_000_000)
        let mondayOpen = fridayClose.addingTimeInterval(65 * 3_600)
        let sunday = fridayClose.addingTimeInterval(44 * 3_600)
        let quote = try makeEndOfDayQuote(
            instrument: instrument,
            marketTimestamp: fridayClose,
            nextRegularOpenAt: mondayOpen
        )
        let quoteWithoutBoundary = try makeEndOfDayQuote(
            instrument: instrument,
            marketTimestamp: fridayClose,
            nextRegularOpenAt: nil
        )
        let policy = try providerPolicy(identifier: "provider.example")

        let duringClosure = MarketQuoteResolver.latest(
            for: instrument,
            observations: [quote],
            at: sunday,
            policy: policy
        )
        let afterOpen = MarketQuoteResolver.latest(
            for: instrument,
            observations: [quote],
            at: mondayOpen,
            policy: policy
        )
        let withoutBoundary = MarketQuoteResolver.latest(
            for: instrument,
            observations: [quoteWithoutBoundary],
            at: mondayOpen,
            policy: policy
        )

        XCTAssertEqual(
            selectedAssessment(duringClosure)?.freshness,
            .closedSessionCarryForward(nextRegularOpenAt: mondayOpen)
        )
        XCTAssertEqual(selectedAssessment(afterOpen)?.freshness, .stale)
        XCTAssertEqual(selectedAssessment(withoutBoundary)?.freshness, .current)

        let rejectionPolicy = try MarketDataPolicy(
            accessMode: .foregroundOnDemand,
            approvedProviderIdentifier: "provider.example",
            staleQuoteUsage: .reject
        )
        let position = try makeConnectedPosition(
            instrument: instrument,
            quantity: 1,
            recordedValue: 100
        )
        let valuation = try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [try Money(150, currency: instrument.quoteCurrency)],
            positions: [position],
            observations: [quote],
            at: mondayOpen,
            policy: rejectionPolicy
        )

        XCTAssertEqual(valuation.amounts.first?.money.amount, 150)
        XCTAssertTrue(valuation.evidence.isEmpty)
        XCTAssertEqual(
            valuation.gaps.first?.reason,
            .quoteUnavailable(.staleRejected)
        )
    }

    func testClosedLastTradeUsesSuppliedSessionBoundaryBeforeMaximumAge() throws {
        let instrument = try makeInstrument()
        let tradedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let nextOpen = tradedAt.addingTimeInterval(48 * 3_600)
        let beforeOpen = nextOpen.addingTimeInterval(-1)
        let quote = try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(100, currency: instrument.quoteCurrency),
            marketTimestamp: tradedAt,
            receivedAt: tradedAt,
            quoteType: .lastTrade,
            delay: try MarketQuoteDelay(kind: .delayed, seconds: 900),
            quality: .providerReported,
            session: try MarketSessionContext(
                state: .closed,
                nextRegularOpenAt: nextOpen
            ),
            provenance: try MarketQuoteProvenance(
                sourceKind: .provider,
                sourceIdentifier: "provider.example"
            )
        )
        let policy = try providerPolicy(identifier: "provider.example")

        let carried = MarketQuoteResolver.latest(
            for: instrument,
            observations: [quote],
            at: beforeOpen,
            policy: policy
        )
        let stale = MarketQuoteResolver.latest(
            for: instrument,
            observations: [quote],
            at: nextOpen,
            policy: policy
        )

        XCTAssertEqual(
            selectedAssessment(carried)?.freshness,
            .closedSessionCarryForward(nextRegularOpenAt: nextOpen)
        )
        XCTAssertEqual(selectedAssessment(stale)?.freshness, .stale)
    }

    func testBatchReportsPartialCompletenessWithoutInventingZeroQuote() throws {
        let instrument = try makeInstrument()
        let missingID = UUID()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = try makeProviderQuote(
            instrument: instrument,
            amount: 100,
            marketTimestamp: instant,
            receivedAt: instant
        )
        let batch = try MarketQuoteBatch(
            requestID: UUID(),
            requestedInstrumentIDs: [instrument.id, missingID],
            requestedAt: instant,
            completedAt: instant,
            results: [
                try MarketQuoteResult(
                    instrumentID: instrument.id,
                    outcome: .observation(observation)
                ),
                try MarketQuoteResult(
                    instrumentID: missingID,
                    outcome: .unavailable(.providerFailure)
                )
            ]
        )

        XCTAssertEqual(batch.completeness, .partial)
        XCTAssertEqual(batch.observations, [observation])
        XCTAssertFalse(batch.observations.contains { $0.unitPrice.amount == .zero })
    }

    func testProviderResponseRequiresExactRequestAndProviderProvenance() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let request = try MarketQuoteRequest(
            instruments: [instrument],
            requestedAt: instant,
            reason: .userInitiated
        )
        let descriptor = try MarketDataProviderDescriptor(
            identifier: "provider.example",
            supportedKinds: [.equity]
        )
        let validObservation = try makeProviderQuote(
            instrument: instrument,
            amount: 100,
            marketTimestamp: instant,
            receivedAt: instant
        )
        let valid = try MarketQuoteBatch(
            requestID: request.id,
            requestedInstrumentIDs: [instrument.id],
            requestedAt: request.requestedAt,
            completedAt: instant,
            results: [try MarketQuoteResult(
                instrumentID: instrument.id,
                outcome: .observation(validObservation)
            )]
        )

        XCTAssertEqual(
            try MarketQuoteProviderResponseValidator.validated(
                valid,
                for: request,
                provider: descriptor
            ),
            valid
        )

        let imported = try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(101, currency: instrument.quoteCurrency),
            marketTimestamp: instant,
            receivedAt: instant,
            quoteType: .lastTrade,
            delay: .realTime,
            quality: .providerReported,
            session: try MarketSessionContext(state: .regular),
            provenance: try MarketQuoteProvenance(
                sourceKind: .imported,
                sourceIdentifier: "moneyup.import"
            )
        )
        let importedBatch = try batch(
            observation: imported,
            request: request,
            completedAt: instant
        )
        XCTAssertThrowsError(try MarketQuoteProviderResponseValidator.validated(
            importedBatch,
            for: request,
            provider: descriptor
        )) { error in
            XCTAssertEqual(error as? MarketQuoteBatchError, .sourceMismatch)
        }

        let wrongSource = try makeProviderQuote(
            instrument: instrument,
            amount: 102,
            marketTimestamp: instant,
            receivedAt: instant,
            sourceIdentifier: "provider.other"
        )
        let wrongSourceBatch = try batch(
            observation: wrongSource,
            request: request,
            completedAt: instant
        )
        XCTAssertThrowsError(try MarketQuoteProviderResponseValidator.validated(
            wrongSourceBatch,
            for: request,
            provider: descriptor
        )) { error in
            XCTAssertEqual(error as? MarketQuoteBatchError, .sourceMismatch)
        }

        let wrongRequestBatch = try MarketQuoteBatch(
            requestID: UUID(),
            requestedInstrumentIDs: [instrument.id],
            requestedAt: request.requestedAt,
            completedAt: instant,
            results: [try MarketQuoteResult(
                instrumentID: instrument.id,
                outcome: .observation(validObservation)
            )]
        )
        XCTAssertThrowsError(try MarketQuoteProviderResponseValidator.validated(
            wrongRequestBatch,
            for: request,
            provider: descriptor
        )) { error in
            XCTAssertEqual(error as? MarketQuoteBatchError, .requestMismatch)
        }
    }

    func testProviderResponseRejectsSameInstrumentIDWithWrongQuoteCurrency() throws {
        let instrument = try makeInstrument()
        let wrongCurrencyInstrument = try InstrumentIdentity(
            id: instrument.id,
            kind: instrument.kind,
            symbol: instrument.symbol,
            venue: instrument.venue,
            quoteCurrency: try CurrencyCode("SGD")
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let request = try MarketQuoteRequest(
            instruments: [instrument],
            requestedAt: instant,
            reason: .userInitiated
        )
        let descriptor = try MarketDataProviderDescriptor(
            identifier: "provider.example",
            supportedKinds: [.equity]
        )
        let wrongCurrencyObservation = try makeProviderQuote(
            instrument: wrongCurrencyInstrument,
            amount: 100,
            marketTimestamp: instant,
            receivedAt: instant
        )
        let wrongCurrencyBatch = try batch(
            observation: wrongCurrencyObservation,
            request: request,
            completedAt: instant
        )

        XCTAssertThrowsError(try MarketQuoteProviderResponseValidator.validated(
            wrongCurrencyBatch,
            for: request,
            provider: descriptor
        )) { error in
            XCTAssertEqual(error as? MarketQuoteBatchError, .requestMismatch)
        }
    }

    func testProviderZeroPriceIsRejectedRatherThanTreatedAsUnavailableValue() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertThrowsError(try makeProviderQuote(
            instrument: instrument,
            amount: .zero,
            marketTimestamp: instant,
            receivedAt: instant
        )) { error in
            XCTAssertEqual(error as? MarketDataModelError, .invalidPrice)
        }
    }

    func testProviderFailurePreservesLastStoredObservationAndNeverFallsToZero() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let stored = try makeProviderQuote(
            instrument: instrument,
            amount: 110,
            marketTimestamp: instant,
            receivedAt: instant
        )
        let failure = try MarketQuoteBatch(
            requestID: UUID(),
            requestedInstrumentIDs: [instrument.id],
            requestedAt: instant.addingTimeInterval(60),
            completedAt: instant.addingTimeInterval(61),
            results: [try MarketQuoteResult(
                instrumentID: instrument.id,
                outcome: .unavailable(.providerFailure)
            )]
        )
        let position = try makeConnectedPosition(
            instrument: instrument,
            quantity: 1,
            recordedValue: 100
        )
        let result = try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [try Money(150, currency: instrument.quoteCurrency)],
            positions: [position],
            observations: [stored] + failure.observations,
            at: instant.addingTimeInterval(120),
            policy: try providerPolicy(identifier: "provider.example")
        )

        XCTAssertEqual(result.amounts.first?.money.amount, 160)
        XCTAssertEqual(result.evidence.first?.quoteObservationID, stored.id)
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func testMissingQuoteRetainsRecordedPositionInsteadOfFalseZero() throws {
        let instrument = try makeInstrument()
        let position = try makeConnectedPosition(
            instrument: instrument,
            quantity: 1,
            recordedValue: 100
        )

        let result = try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [try Money(150, currency: instrument.quoteCurrency)],
            positions: [position],
            observations: [],
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.amounts.first?.money.amount, 150)
        XCTAssertEqual(result.completeness, .unavailable)
        XCTAssertEqual(
            result.gaps.first?.reason,
            .quoteUnavailable(.noObservation)
        )
    }

    func testStaleRejectedQuoteRetainsRecordedValueAndSurfacesGap() throws {
        let instrument = try makeInstrument()
        let quoteTime = Date(timeIntervalSince1970: 1_800_000_000)
        let quote = try makeManualQuote(
            instrument: instrument,
            amount: 120,
            marketTimestamp: quoteTime
        )
        let position = try makeConnectedPosition(
            instrument: instrument,
            quantity: 1,
            recordedValue: 100
        )
        let policy = try MarketDataPolicy(
            accessMode: .manualOnly,
            approvedProviderIdentifier: nil,
            maximumAgeSeconds: 60,
            staleQuoteUsage: .reject
        )

        let result = try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [try Money(150, currency: instrument.quoteCurrency)],
            positions: [position],
            observations: [quote],
            at: quoteTime.addingTimeInterval(61),
            policy: policy
        )

        XCTAssertEqual(result.amounts.first?.money.amount, 150)
        XCTAssertEqual(
            result.gaps.first?.reason,
            .quoteUnavailable(.staleRejected)
        )
    }

    func testValuationReplacesConnectedLedgerValueExactlyOnce() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let quote = try makeManualQuote(
            instrument: instrument,
            amount: 120,
            marketTimestamp: instant
        )
        let position = try makeConnectedPosition(
            instrument: instrument,
            quantity: 1,
            recordedValue: 100
        )

        let result = try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [try Money(150, currency: instrument.quoteCurrency)],
            positions: [position],
            observations: [quote],
            at: instant
        )

        XCTAssertEqual(result.amounts.first?.money.amount, 170)
        XCTAssertNotEqual(result.amounts.first?.money.amount, 270)
        XCTAssertEqual(result.evidence.first?.recordedValueReplaced?.amount, 100)
    }

    func testDuplicateLedgerCoverageIsRejectedBeforeDoubleCounting() throws {
        let firstInstrument = try makeInstrument()
        let secondInstrument = try makeInstrument(id: UUID(), symbol: "AAPL")
        let accountID = UUID()
        let usd = firstInstrument.quoteCurrency
        let first = try MarketValuationPosition(
            holdingID: UUID(),
            instrument: firstInstrument,
            quantity: 1,
            ledgerCoverage: .replaceRecordedPosition(
                accountID: accountID,
                value: try Money(10, currency: usd)
            )
        )
        let second = try MarketValuationPosition(
            holdingID: UUID(),
            instrument: secondInstrument,
            quantity: 1,
            ledgerCoverage: .replaceRecordedPosition(
                accountID: accountID,
                value: try Money(10, currency: usd)
            )
        )

        XCTAssertThrowsError(try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [try Money(20, currency: usd)],
            positions: [first, second],
            observations: [],
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )) { error in
            XCTAssertEqual(
                error as? MarketValuationError,
                .duplicateLedgerPositionAccount
            )
        }
    }

    func testDecimalPositionValuationRoundsOnceAtDestinationCurrency() throws {
        let instrument = try makeInstrument()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let quote = try makeManualQuote(
            instrument: instrument,
            amount: Decimal(string: "0.1", locale: posix)!,
            marketTimestamp: instant
        )
        let position = try MarketValuationPosition(
            holdingID: UUID(),
            instrument: instrument,
            quantity: Decimal(string: "0.3", locale: posix)!,
            ledgerCoverage: .addConfirmedLegacyPosition
        )

        let result = try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [try Money(0, currency: instrument.quoteCurrency)],
            positions: [position],
            observations: [quote],
            at: instant
        )

        XCTAssertEqual(
            result.amounts.first?.money.amount,
            Decimal(string: "0.03", locale: posix)
        )
    }

    func testMixedCurrenciesWithoutFXNeverProducePartialBaseTotal() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let conversion = MarketValuationConversionContext(
            baseCurrency: sgd,
            origin: TransactionOriginContext.capture(
                for: instant,
                calendar: calendar,
                timeZone: utc
            ),
            rates: []
        )

        let result = try MarketEstimatedNetWorthEngine.estimate(
            recordedAmounts: [
                try Money(500, currency: sgd),
                try Money(100, currency: usd)
            ],
            positions: [],
            observations: [],
            at: instant,
            conversion: conversion
        )

        XCTAssertEqual(result.amounts.map(\.money.currency), [sgd, usd])
        XCTAssertNil(result.estimatedBaseTotal)
        XCTAssertEqual(result.missingConversionCurrencies, [usd])
    }

    func testManualLegacyMappingPreservesHoldingAndPricePointIdentities() throws {
        let usd = try CurrencyCode("USD")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 2,
            price: try Money(100, currency: usd),
            priceAsOf: instant
        )

        let result = try LegacyMarketDataMigration.map(holding: holding)

        guard case let .mapped(mapping) = result else {
            return XCTFail("Expected a local legacy mapping.")
        }
        XCTAssertEqual(mapping.instrument.id, holding.id)
        XCTAssertEqual(mapping.instrument.resolution, .manualLegacy)
        XCTAssertEqual(mapping.observations.map(\.id), holding.priceHistory.map(\.id))
        XCTAssertFalse(mapping.omittedUndatedCurrentPrice)
        XCTAssertEqual(holding.price?.amount, 100)
    }

    func testManualLegacyMigrationDoesNotInventMissingPriceDate() throws {
        let usd = try CurrencyCode("USD")
        let holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 2,
            price: try Money(100, currency: usd)
        )

        let result = try LegacyMarketDataMigration.map(holding: holding)

        guard case let .mapped(mapping) = result else {
            return XCTFail("Expected a local legacy mapping.")
        }
        XCTAssertTrue(mapping.observations.isEmpty)
        XCTAssertTrue(mapping.omittedUndatedCurrentPrice)
    }

    func testManualLegacyMigrationOmitsSoleCorrectedValuation() throws {
        let usd = try CurrencyCode("USD")
        let valuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 1
        )
        try holding.recordPrice(
            try Money(100, currency: usd),
            asOf: valuedAt
        )
        let target = try XCTUnwrap(holding.latestCorrectableActivity)
        _ = try holding.correctLatestActivity(
            targetActivityID: target.id,
            correctionEntryID: nil,
            occurredAt: valuedAt.addingTimeInterval(60)
        )

        let result = try LegacyMarketDataMigration.map(holding: holding)

        guard case let .mapped(mapping) = result else {
            return XCTFail("Expected a local legacy mapping.")
        }
        XCTAssertTrue(mapping.observations.isEmpty)
    }

    func testManualLegacyMigrationRetainsRestorationAfterValuationCorrection() throws {
        let usd = try CurrencyCode("USD")
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let latestDate = firstDate.addingTimeInterval(60)
        let correctedAt = latestDate.addingTimeInterval(60)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 1
        )
        try holding.recordPrice(try Money(90, currency: usd), asOf: firstDate)
        try holding.recordPrice(try Money(100, currency: usd), asOf: latestDate)
        let target = try XCTUnwrap(holding.latestCorrectableActivity)
        _ = try holding.correctLatestActivity(
            targetActivityID: target.id,
            correctionEntryID: nil,
            occurredAt: correctedAt
        )
        let restorationID = try XCTUnwrap(
            holding.corrections.last?.restorationPricePointID
        )

        let result = try LegacyMarketDataMigration.map(holding: holding)

        guard case let .mapped(mapping) = result else {
            return XCTFail("Expected a local legacy mapping.")
        }
        XCTAssertFalse(mapping.observations.contains { $0.id == target.id })
        XCTAssertTrue(mapping.observations.contains { $0.id == restorationID })
        let resolution = MarketQuoteResolver.latest(
            for: mapping.instrument,
            observations: mapping.observations,
            at: correctedAt
        )
        XCTAssertEqual(selectedObservation(resolution)?.id, restorationID)
        XCTAssertEqual(selectedObservation(resolution)?.unitPrice.amount, 90)
    }

    func testManualLegacyMigrationDoesNotReviveSupersededRestoration() throws {
        let usd = try CurrencyCode("USD")
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let secondDate = firstDate.addingTimeInterval(60)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 1
        )
        try holding.recordPrice(try Money(90, currency: usd), asOf: firstDate)
        try holding.recordPrice(try Money(100, currency: usd), asOf: secondDate)
        let secondTarget = try XCTUnwrap(holding.latestCorrectableActivity)
        _ = try holding.correctLatestActivity(
            targetActivityID: secondTarget.id,
            correctionEntryID: nil,
            occurredAt: secondDate.addingTimeInterval(60)
        )
        let supersededRestorationID = try XCTUnwrap(
            holding.corrections.last?.restorationPricePointID
        )
        let firstTarget = try XCTUnwrap(holding.latestCorrectableActivity)
        _ = try holding.correctLatestActivity(
            targetActivityID: firstTarget.id,
            correctionEntryID: nil,
            occurredAt: secondDate.addingTimeInterval(120)
        )
        XCTAssertNil(holding.price)
        XCTAssertNil(holding.priceAsOf)

        let result = try LegacyMarketDataMigration.map(holding: holding)

        guard case let .mapped(mapping) = result else {
            return XCTFail("Expected a local legacy mapping.")
        }
        XCTAssertFalse(mapping.observations.contains {
            $0.id == supersededRestorationID
        })
        XCTAssertTrue(mapping.observations.isEmpty)
    }

    func testManualLegacyMigrationUsesSequenceForEqualTimestampPrices() throws {
        let usd = try CurrencyCode("USD")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let olderID = try XCTUnwrap(
            UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        )
        let newerID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let older = try HoldingPricePoint(
            id: olderID,
            price: try Money(90, currency: usd),
            asOf: instant,
            activitySequence: 1
        )
        let newer = try HoldingPricePoint(
            id: newerID,
            price: try Money(100, currency: usd),
            asOf: instant,
            activitySequence: 2
        )
        let holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: newer.price,
            priceAsOf: instant,
            priceHistory: [older, newer]
        )

        let result = try LegacyMarketDataMigration.map(holding: holding)

        guard case let .mapped(mapping) = result else {
            return XCTFail("Expected a local legacy mapping.")
        }
        XCTAssertEqual(mapping.observations.count, 2)
        XCTAssertEqual(
            Set(mapping.observations.map(\.id)),
            Set([olderID, newerID])
        )
        let observationsByID = Dictionary(
            uniqueKeysWithValues: mapping.observations.map { ($0.id, $0) }
        )
        XCTAssertEqual(
            observationsByID[olderID]?.provenance.sourceRecordIdentifier,
            olderID.uuidString
        )
        XCTAssertEqual(observationsByID[olderID]?.provenance.sourceSequence, 1)
        XCTAssertEqual(
            observationsByID[newerID]?.provenance.sourceRecordIdentifier,
            newerID.uuidString
        )
        XCTAssertEqual(observationsByID[newerID]?.provenance.sourceSequence, 2)

        let forward = MarketQuoteResolver.latest(
            for: mapping.instrument,
            observations: mapping.observations,
            at: instant
        )
        let reverse = MarketQuoteResolver.latest(
            for: mapping.instrument,
            observations: Array(mapping.observations.reversed()),
            at: instant
        )
        XCTAssertEqual(selectedObservation(forward)?.id, newerID)
        XCTAssertEqual(selectedObservation(forward)?.unitPrice.amount, 100)
        XCTAssertEqual(selectedObservation(reverse)?.id, newerID)
    }

    func testManualLegacyMigrationOmitsCorrectedPurchaseAndSaleLinkedPrices() throws {
        let usd = try CurrencyCode("USD")
        let purchasedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let soldAt = purchasedAt.addingTimeInterval(60)

        let purchaseEntryID = UUID()
        var correctedPurchase = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: .zero,
            positionAccountID: UUID()
        )
        try correctedPurchase.recordPurchase(
            quantity: 1,
            unitCost: try Money(10, currency: usd),
            occurredAt: purchasedAt,
            entryID: purchaseEntryID
        )
        try correctedPurchase.recordPrice(
            try Money(10, currency: usd),
            asOf: purchasedAt,
            entryID: purchaseEntryID
        )
        let purchasePriceID = try XCTUnwrap(correctedPurchase.priceHistory.last?.id)
        let purchaseTarget = try XCTUnwrap(correctedPurchase.latestCorrectableActivity)
        _ = try correctedPurchase.correctLatestActivity(
            targetActivityID: purchaseTarget.id,
            correctionEntryID: UUID(),
            occurredAt: soldAt
        )

        guard case let .mapped(purchaseMapping) = try LegacyMarketDataMigration.map(
            holding: correctedPurchase
        ) else {
            return XCTFail("Expected a local purchase mapping.")
        }
        XCTAssertFalse(purchaseMapping.observations.contains {
            $0.id == purchasePriceID
        })

        let saleEntryID = UUID()
        var correctedSale = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: .zero,
            positionAccountID: UUID()
        )
        try correctedSale.recordPurchase(
            quantity: 2,
            unitCost: try Money(10, currency: usd),
            occurredAt: purchasedAt,
            entryID: purchaseEntryID
        )
        try correctedSale.recordPrice(
            try Money(10, currency: usd),
            asOf: purchasedAt,
            entryID: purchaseEntryID
        )
        _ = try correctedSale.recordSale(
            quantity: 1,
            unitPrice: try Money(15, currency: usd),
            occurredAt: soldAt,
            entryID: saleEntryID
        )
        try correctedSale.recordPrice(
            try Money(15, currency: usd),
            asOf: soldAt,
            entryID: saleEntryID
        )
        let salePriceID = try XCTUnwrap(correctedSale.priceHistory.last?.id)
        let saleTarget = try XCTUnwrap(correctedSale.latestCorrectableActivity)
        _ = try correctedSale.correctLatestActivity(
            targetActivityID: saleTarget.id,
            correctionEntryID: UUID(),
            occurredAt: soldAt.addingTimeInterval(60)
        )

        guard case let .mapped(saleMapping) = try LegacyMarketDataMigration.map(
            holding: correctedSale
        ) else {
            return XCTFail("Expected a local sale mapping.")
        }
        XCTAssertFalse(saleMapping.observations.contains { $0.id == salePriceID })
        let restorationID = try XCTUnwrap(
            correctedSale.corrections.last?.restorationPricePointID
        )
        XCTAssertTrue(saleMapping.observations.contains { $0.id == restorationID })
    }
}

private extension MarketDataFoundationTests {
    var posix: Locale { Locale(identifier: "en_US_POSIX") }

    func makeInstrument(
        id: UUID = UUID(),
        symbol: String = "MU"
    ) throws -> InstrumentIdentity {
        try InstrumentIdentity(
            id: id,
            kind: .equity,
            symbol: symbol,
            venue: try MarketVenue(kind: .mic, code: "XNAS"),
            quoteCurrency: try CurrencyCode("USD")
        )
    }

    func makeManualQuote(
        instrument: InstrumentIdentity,
        amount: Decimal,
        marketTimestamp: Date
    ) throws -> MarketQuoteObservation {
        try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(amount, currency: instrument.quoteCurrency),
            marketTimestamp: marketTimestamp,
            receivedAt: marketTimestamp,
            quoteType: .manual,
            delay: .notApplicable,
            quality: .userEntered,
            session: try MarketSessionContext(state: .unknown),
            provenance: try MarketQuoteProvenance(
                sourceKind: .manual,
                sourceIdentifier: "moneyup.manual"
            )
        )
    }

    func makeProviderQuote(
        instrument: InstrumentIdentity,
        amount: Decimal,
        marketTimestamp: Date,
        receivedAt: Date,
        sourceRecordIdentifier: String? = nil,
        sourceSequence: Int64? = nil,
        sourceIdentifier: String = "provider.example"
    ) throws -> MarketQuoteObservation {
        try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(amount, currency: instrument.quoteCurrency),
            marketTimestamp: marketTimestamp,
            receivedAt: receivedAt,
            quoteType: .lastTrade,
            delay: try MarketQuoteDelay(kind: .delayed, seconds: 900),
            quality: .providerReported,
            session: try MarketSessionContext(state: .regular),
            provenance: try MarketQuoteProvenance(
                sourceKind: .provider,
                sourceIdentifier: sourceIdentifier,
                sourceRecordIdentifier: sourceRecordIdentifier,
                sourceSequence: sourceSequence
            )
        )
    }

    func batch(
        observation: MarketQuoteObservation,
        request: MarketQuoteRequest,
        completedAt: Date
    ) throws -> MarketQuoteBatch {
        try MarketQuoteBatch(
            requestID: request.id,
            requestedInstrumentIDs: request.instruments.map(\.id),
            requestedAt: request.requestedAt,
            completedAt: completedAt,
            results: [try MarketQuoteResult(
                instrumentID: observation.instrumentID,
                outcome: .observation(observation)
            )]
        )
    }

    func makeEndOfDayQuote(
        instrument: InstrumentIdentity,
        marketTimestamp: Date,
        nextRegularOpenAt: Date?
    ) throws -> MarketQuoteObservation {
        try MarketQuoteObservation(
            instrument: instrument,
            unitPrice: try Money(100, currency: instrument.quoteCurrency),
            marketTimestamp: marketTimestamp,
            receivedAt: marketTimestamp,
            quoteType: .endOfDay,
            delay: .endOfDay,
            quality: .official,
            session: try MarketSessionContext(
                state: .closed,
                nextRegularOpenAt: nextRegularOpenAt
            ),
            provenance: try MarketQuoteProvenance(
                sourceKind: .provider,
                sourceIdentifier: "provider.example"
            )
        )
    }

    func providerPolicy(
        identifier: String,
        maximumAgeSeconds: Int = 7 * 86_400
    ) throws -> MarketDataPolicy {
        try MarketDataPolicy(
            accessMode: .foregroundOnDemand,
            approvedProviderIdentifier: identifier,
            maximumAgeSeconds: maximumAgeSeconds
        )
    }

    func makeConnectedPosition(
        instrument: InstrumentIdentity,
        quantity: Decimal,
        recordedValue: Decimal
    ) throws -> MarketValuationPosition {
        try MarketValuationPosition(
            holdingID: UUID(),
            instrument: instrument,
            quantity: quantity,
            ledgerCoverage: .replaceRecordedPosition(
                accountID: UUID(),
                value: try Money(
                    recordedValue,
                    currency: instrument.quoteCurrency
                )
            )
        )
    }

    func selectedAssessment(
        _ resolution: MarketQuoteResolution
    ) -> MarketQuoteAssessment? {
        if case let .selected(assessment) = resolution { return assessment }
        return nil
    }

    func selectedObservation(
        _ resolution: MarketQuoteResolution
    ) -> MarketQuoteObservation? {
        selectedAssessment(resolution)?.observation
    }
}
