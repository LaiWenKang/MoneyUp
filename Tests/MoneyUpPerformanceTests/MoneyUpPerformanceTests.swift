import Foundation
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class MoneyUpPerformanceTests: XCTestCase {
    private static let fixture: MoneyUpPerformanceFixture = {
        do {
            return try MoneyUpPerformanceFixture.makeSeeded()
        } catch {
            preconditionFailure("Cannot seed MoneyUp performance fixture: \(error)")
        }
    }()

    private var metrics: [any XCTMetric] {
        [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric(),
            XCTStorageMetric()
        ]
    }

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = MoneyUpPerformanceFixture.measurementIterationCount
        return options
    }

    func testFixtureContract() throws {
        let fixture = Self.fixture
        XCTAssertEqual(fixture.manifest.corpusProfile, "intelligence-v1")
        XCTAssertEqual(
            fixture.manifest.oracleSHA256,
            PerformanceIntelligenceCorpus.oracleSHA256
        )
        XCTAssertEqual(
            fixture.manifest.logicalCSVPayloadSHA256,
            PerformanceIntelligenceCorpus.logicalCSVPayloadSHA256
        )
        XCTAssertEqual(fixture.manifest.currencies, ["KWD", "SGD", "USD"])
        XCTAssertEqual(fixture.manifest.expectedFindingCount, 6)
        XCTAssertEqual(fixture.manifest.excludedIntelligenceEntryCount, 2)
        let store = try fixture.openStore()
        defer { try? waitForPerformanceOperation { await store.close() } }
        let counts = try waitForPerformanceOperation {
            try await store.recordCountSnapshot()
        }
        XCTAssertEqual(
            counts.count(in: .journalEntries),
            MoneyUpPerformanceFixture.journalEntryCount
        )
        XCTAssertEqual(
            counts.count(in: .budgetEntryAttributions),
            MoneyUpPerformanceFixture.journalEntryCount
        )
        XCTAssertEqual(
            counts.count(in: .scheduledTransactions),
            MoneyUpPerformanceFixture.scheduledTransactionCount
        )
        let data = try JSONEncoder.sorted.encode(fixture.manifest)
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "MoneyUpPerformanceFixture.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMeasureStoreOpenCloseBaseline() throws {
        let fixture = Self.fixture
        let databaseURLs = try (0..<MoneyUpPerformanceFixture.measurementInvocationCount)
            .map { try fixture.databaseCopy(named: "store-open-close-\($0)") }
        do {
            let preflightStore = try fixture.openStore(at: databaseURLs[0])
            let preflightCount = try waitForPerformanceOperation {
                try await preflightStore.count(in: .journalEntries)
            }
            try waitForPerformanceOperation { await preflightStore.close() }
            XCTAssertEqual(
                preflightCount,
                MoneyUpPerformanceFixture.journalEntryCount
            )
        }
        var index = 0
        measureBaseline {
            let store = try fixture.openStore(at: databaseURLs[index])
            index += 1
            try waitForPerformanceOperation { await store.close() }
            return index
        }
    }

    func testMeasureStoreLoadBaseline() throws {
        let fixture = Self.fixture
        let store = try fixture.openStore()
        defer { try? waitForPerformanceOperation { await store.close() } }
        let preflight = try waitForPerformanceOperation {
            try await PerformanceOperations.loadBook(
                store: store,
                accounts: fixture.accounts
            )
        }
        XCTAssertEqual(preflight.accountCount, fixture.accounts.count)
        XCTAssertEqual(
            preflight.scheduleCount,
            MoneyUpPerformanceFixture.scheduledTransactionCount
        )
        XCTAssertEqual(
            preflight.ledgerEntryCount,
            MoneyUpPerformanceFixture.journalEntryCount
        )
        XCTAssertEqual(preflight.receiptAttachmentCount, 0)
        XCTAssertEqual(
            preflight.budgetAttributionCount,
            MoneyUpPerformanceFixture.journalEntryCount
        )
        measureBaseline {
            try waitForPerformanceOperation {
                let result = try await PerformanceOperations.loadBook(
                    store: store,
                    accounts: fixture.accounts
                )
                return result.checksum
            }
        }
    }

    func testMeasureSaveBaseline() throws {
        let fixture = Self.fixture
        let invocationCount = MoneyUpPerformanceFixture.measurementInvocationCount
        let stores = try (0..<invocationCount).map { index in
            let databaseURL = try fixture.databaseCopy(named: "save-\(index)")
            return try fixture.openStore(at: databaseURL)
        }
        defer {
            for store in stores {
                try? waitForPerformanceOperation { await store.close() }
            }
        }
        let entries = try (0..<invocationCount).map {
            try fixture.makeAdditionalEntry(offset: $0)
        }
        var index = 0
        measureBaseline {
            let store = stores[index]
            let entry = entries[index]
            index += 1
            let attribution = try BudgetEntryAttribution(
                entry: entry,
                originTimeZoneIdentifier: "UTC"
            )
            let writes = [
                try RecordWrite(
                    entry,
                    id: entry.id.uuidString,
                    in: .journalEntries
                ),
                try RecordWrite(
                    attribution,
                    id: attribution.id.uuidString,
                    in: .budgetEntryAttributions
                )
            ]
            return try waitForPerformanceOperation {
                try await store.write(writes)
                return entry.postings.count
            }
        }
        for store in stores {
            let counts = try waitForPerformanceOperation {
                try await store.recordCountSnapshot()
            }
            XCTAssertEqual(
                counts.count(in: .journalEntries),
                MoneyUpPerformanceFixture.journalEntryCount + 1
            )
            XCTAssertEqual(
                counts.count(in: .budgetEntryAttributions),
                MoneyUpPerformanceFixture.journalEntryCount + 1
            )
        }
    }

    func testMeasureHistoryPageAndQueryBaseline() throws {
        let fixture = Self.fixture
        let store = try fixture.openStore()
        defer { try? waitForPerformanceOperation { await store.close() } }
        let preflight = try waitForPerformanceOperation {
            try await PerformanceOperations.historyPageAndQuery(
                store: store,
                accounts: fixture.accounts,
                calendar: fixture.calendar
            )
        }
        XCTAssertEqual(preflight.matchCount, 80)
        XCTAssertGreaterThan(preflight.pageCount, 1)
        XCTAssertEqual(preflight.issueCount, 0)
        measureBaseline {
            try waitForPerformanceOperation {
                let result = try await PerformanceOperations.historyPageAndQuery(
                    store: store,
                    accounts: fixture.accounts,
                    calendar: fixture.calendar
                )
                return result.checksum
            }
        }
    }

    func testMeasureExportBaseline() throws {
        let fixture = Self.fixture
        let store = try fixture.openStore()
        let recovered = try waitForPerformanceOperation {
            try await store.fetchAllIdentifiedRecovering(
                JournalEntry.self,
                from: .journalEntries
            )
        }
        try waitForPerformanceOperation { await store.close() }
        XCTAssertTrue(recovered.issues.isEmpty)
        XCTAssertEqual(
            recovered.values.count,
            MoneyUpPerformanceFixture.journalEntryCount
        )
        let preflight = PerformanceOperations.export(
            entries: recovered.values,
            accounts: fixture.accounts
        )
        XCTAssertGreaterThan(preflight.csvByteCount, 0)
        XCTAssertGreaterThan(preflight.xlsxByteCount, 0)
        measureBaseline {
            PerformanceOperations.export(
                entries: recovered.values,
                accounts: fixture.accounts
            ).checksum
        }
    }

    func testMeasureArchiveBaseline() throws {
        let fixture = Self.fixture
        let store = try fixture.openStore()
        defer { try? waitForPerformanceOperation { await store.close() } }
        let destinations = (0..<MoneyUpPerformanceFixture.measurementInvocationCount)
            .map { fixture.directoryURL.appendingPathComponent("archive-\($0).moneyup") }
        var index = 0
        measureBaseline {
            let destination = destinations[index]
            index += 1
            let checksum = index
            return try waitForPerformanceOperation {
                try await store.exportPortableArchive(
                    to: destination,
                    password: MoneyUpPerformanceFixture.archivePassword
                )
                return checksum
            }
        }
        for destination in destinations {
            XCTAssertGreaterThan(
                try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                0
            )
        }
    }

    func testMeasureRestoreBaseline() throws {
        let fixture = Self.fixture
        let sourceStore = try fixture.openStore()
        defer { try? waitForPerformanceOperation { await sourceStore.close() } }
        let archiveURL = fixture.directoryURL.appendingPathComponent(
            "restore-source.moneyup"
        )
        try waitForPerformanceOperation {
            try await sourceStore.exportPortableArchive(
                to: archiveURL,
                password: MoneyUpPerformanceFixture.archivePassword
            )
        }
        let stores = try (0..<MoneyUpPerformanceFixture.measurementInvocationCount)
            .map { try fixture.emptyStore(named: "restore-\($0)") }
        defer {
            for store in stores {
                try? waitForPerformanceOperation { await store.close() }
            }
        }
        var index = 0
        measureBaseline {
            let store = stores[index]
            index += 1
            let checksum = index
            return try waitForPerformanceOperation {
                try await store.restorePortableArchive(
                    from: archiveURL,
                    password: MoneyUpPerformanceFixture.archivePassword
                )
                return checksum
            }
        }
        for store in stores {
            let count = try waitForPerformanceOperation {
                try await store.count(in: .journalEntries)
            }
            XCTAssertEqual(count, MoneyUpPerformanceFixture.journalEntryCount)
        }
    }

    func testMeasureReceiptTextProcessingBaseline() throws {
        let fixture = Self.fixture
        let lines = Self.receiptLines
        let preflight = receiptResult(lines: lines, fixture: fixture)
        XCTAssertEqual(
            preflight.amountCandidates.first,
            Decimal(string: "60.45", locale: Locale(identifier: "en_US_POSIX"))
        )
        XCTAssertFalse(preflight.merchantCandidates.isEmpty)
        XCTAssertFalse(preflight.dateCandidates.isEmpty)
        measureBaseline {
            let result = receiptResult(lines: lines, fixture: fixture)
            return result.amountCandidates.count
                + result.merchantCandidates.count
                + result.dateCandidates.count
        }
    }

    func testMeasureProjectionBaseline() throws {
        let fixture = Self.fixture
        let store = try fixture.openStore()
        defer { try? waitForPerformanceOperation { await store.close() } }
        let preflight = try waitForPerformanceOperation {
            try await PerformanceOperations.projection(
                store: store,
                fixture: fixture
            )
        }
        XCTAssertEqual(preflight.postingEventCount, 20_001)
        XCTAssertGreaterThan(preflight.baseCurrencyCategoryEventCount, 0)
        XCTAssertEqual(
            preflight.scheduleCount,
            MoneyUpPerformanceFixture.scheduledTransactionCount
        )
        XCTAssertEqual(preflight.scheduleIssueCount, 0)
        XCTAssertGreaterThan(preflight.occurrenceCount, 0)
        XCTAssertEqual(preflight.projectedTotal.currency, fixture.currency)
        measureBaseline {
            try waitForPerformanceOperation {
                let result = try await PerformanceOperations.projection(
                    store: store,
                    fixture: fixture
                )
                return result.checksum
            }
        }
    }

    func testMeasureIntelligenceBaseline() throws {
        let fixture = Self.fixture
        let store = try fixture.openStore()
        defer { try? waitForPerformanceOperation { await store.close() } }
        let preflight = try waitForPerformanceOperation {
            try await PerformanceOperations.intelligence(
                store: store,
                corpus: fixture.corpus
            )
        }
        XCTAssertEqual(
            preflight.observationCount,
            EncryptedRecordStore.maximumIntelligenceObservationCount
        )
        XCTAssertEqual(preflight.currencies, Set(["KWD", "SGD", "USD"]))
        XCTAssertEqual(
            preflight.findings,
            fixture.corpus.expectedFindingSignatures
        )
        XCTAssertEqual(preflight.excludedEntryCount, 0)
        measureBaseline {
            try waitForPerformanceOperation {
                let result = try await PerformanceOperations.intelligence(
                    store: store,
                    corpus: fixture.corpus
                )
                return result.checksum
            }
        }
    }

    private func measureBaseline(
        _ operation: () throws -> Int
    ) {
        var failures: [String] = []
        var checksum = 0
        measure(metrics: metrics, options: options) {
            do {
                checksum &+= try autoreleasepool(invoking: operation)
            } catch {
                failures.append(String(describing: error))
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertNotEqual(checksum, Int.min)
    }

    private func receiptResult(
        lines: [String],
        fixture: MoneyUpPerformanceFixture
    ) -> ReceiptParseResult {
        ReceiptTextParser.analyze(
            fromLines: lines,
            now: Date(timeIntervalSince1970: 1_735_689_600),
            calendar: fixture.calendar,
            prefersDayFirst: true,
            locale: Locale(identifier: "en_US_POSIX"),
            accounts: fixture.accounts,
            ocrConfidence: 0.94,
            ocrLineConfidences: Array(repeating: 0.94, count: lines.count)
        )
    }

    private static let receiptLines: [String] = {
        let header = [
            "FIXTURE MARKET",
            "TAX INVOICE",
            "2025-01-01 18:42",
            "Groceries 42.10",
            "Household 18.35"
        ]
        let body = (0..<150).map { index in
            String(format: "Fixture item %03d %d.25", index + 1, index % 90 + 1)
        }
        return header + body + ["GRAND TOTAL USD 60.45", "THANK YOU"]
    }()
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
