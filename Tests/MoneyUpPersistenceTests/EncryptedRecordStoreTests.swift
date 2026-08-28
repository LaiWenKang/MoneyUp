import CryptoKit
import Foundation
@testable import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

private struct VersionOnePortableArchiveEnvelope: Codable {
    let version: Int
    let kdf: String
    let iterations: Int
    let salt: Data
    let ciphertext: Data
}

final class EncryptedRecordStoreTests: XCTestCase {
    func testPortableArchivePBKDFMatchesIndependentSHA256Vectors() throws {
        XCTAssertEqual(PortableArchive.iterationCount, 120_000)
        let expected: [(iterations: Int, bytes: [UInt8])] = [
            (1, [
                0x12, 0x0f, 0xb6, 0xcf, 0xfc, 0xf8, 0xb3, 0x2c,
                0x43, 0xe7, 0x22, 0x52, 0x56, 0xc4, 0xf8, 0x37,
                0xa8, 0x65, 0x48, 0xc9, 0x2c, 0xcc, 0x35, 0x48,
                0x08, 0x05, 0x98, 0x7c, 0xb7, 0x0b, 0xe1, 0x7b
            ]),
            (2, [
                0xae, 0x4d, 0x0c, 0x95, 0xaf, 0x6b, 0x46, 0xd3,
                0x2d, 0x0a, 0xdf, 0xf9, 0x28, 0xf0, 0x6d, 0xd0,
                0x2a, 0x30, 0x3f, 0x8e, 0xf3, 0xc2, 0x51, 0xdf,
                0xd6, 0xe2, 0xd8, 0x5a, 0x95, 0x47, 0x4c, 0x43
            ])
        ]

        for vector in expected {
            XCTAssertEqual(
                try PortableArchive.derivedKeyData(
                    password: "password",
                    salt: Data("salt".utf8),
                    iterations: vector.iterations
                ),
                Data(vector.bytes)
            )
        }
        XCTAssertEqual(
            try PortableArchive.derivedKeyData(
                password: String(repeating: "p", count: 2_048),
                salt: Data("legacy-salt".utf8),
                iterations: 1
            ),
            Data([
                0x28, 0x09, 0x73, 0xdb, 0xaa, 0xe1, 0x0a, 0x3c,
                0xf2, 0x9e, 0x6a, 0x38, 0xaf, 0xf9, 0x92, 0x93,
                0x6f, 0xc6, 0xa2, 0x20, 0x10, 0xf0, 0x04, 0x86,
                0x83, 0x17, 0xa1, 0xd1, 0xaf, 0x92, 0x2e, 0xc6
            ])
        )
    }

    func testPortableArchivePBKDFChecksCancellationDuringDerivation() async {
        let operation = Task.detached { () throws -> Data in
            var checkpointCount = 0
            return try PortableArchive.derivedKeyData(
                password: "correct horse battery staple",
                salt: Data(repeating: 0x41, count: 16),
                iterations: 1_024,
                cancellationProbe: {
                    checkpointCount += 1
                    if checkpointCount == 4 {
                        withUnsafeCurrentTask { task in task?.cancel() }
                    }
                    try Task.checkCancellation()
                }
            )
        }

        do {
            _ = try await operation.value
            XCTFail("A cancelled PBKDF must not finish derivation")
        } catch is CancellationError {
            // The fourth probe occurs inside the PBKDF iteration loop.
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error))")
        }
    }

    func testPortableArchiveSealAndOpenPreserveDetachedCancellation() async throws {
        let snapshot = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: []
        )
        let password = "correct horse battery staple"
        let archive = try PortableArchive.seal(snapshot, password: password)

        let sealOperation = Task.detached { () throws -> Data in
            withUnsafeCurrentTask { task in task?.cancel() }
            return try PortableArchive.seal(snapshot, password: password)
        }
        do {
            _ = try await sealOperation.value
            XCTFail("Cancelled archive sealing must not return an archive")
        } catch is CancellationError {
            // Expected; cancellation is not reclassified as an archive error.
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error))")
        }

        let openOperation = Task.detached { () throws -> DatabaseSnapshot in
            withUnsafeCurrentTask { task in task?.cancel() }
            return try PortableArchive.open(archive, password: password)
        }
        do {
            _ = try await openOperation.value
            XCTFail("Cancelled archive opening must not return a snapshot")
        } catch is CancellationError {
            // Expected; cancellation is not reclassified as authentication.
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error))")
        }
    }

    func testSQLCipherKeepsTemporaryStorageInMemory() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )

        let usesMemoryOnlyTemporaryStorage = try await store
            .usesMemoryOnlyTemporaryStorage()
        XCTAssertTrue(usesMemoryOnlyTemporaryStorage)
        await store.close()
    }

    func testBudgetConfigurationTimelineRoundTripsDatedTreeAndCarryMapping() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let sourceID = UUID()
        let targetID = UUID()
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Asia/Singapore"
        )
        let january = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 1
        )))
        let august = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 1
        )))
        let source = BudgetNode(
            id: sourceID,
            name: "Source",
            limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let target = BudgetNode(
            id: targetID,
            name: "Target",
            limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: january,
                    nodes: [source, target]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: august,
                    nodes: [target],
                    carryMappings: [BudgetCarryMapping(
                        sourceID: sourceID,
                        targetID: targetID
                    )]
                )
            ]
        )

        try await store.upsert(
            timeline,
            id: BudgetConfigurationTimeline.primaryRecordID,
            in: .budgetConfigurationTimelines
        )
        let loaded = try await store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )

        XCTAssertEqual(loaded, timeline)
        await store.close()
    }

    func testSavingsGoalRoundTripsWithExactMovementsAndResetHistory() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        var goal = try SavingsGoal(
            name: "Emergency fund",
            kind: .savingsGoal,
            target: try Money(Decimal(string: "1000.00")!, currency: sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 100_000),
            createdAt: createdAt
        )
        goal = try goal.adding(try SavingsGoalMovement(
            kind: .contribution,
            money: try Money(Decimal(string: "12.34")!, currency: sgd),
            occurredAt: Date(timeIntervalSinceReferenceDate: 200),
            originTimeZoneIdentifier: "Asia/Singapore"
        ))
        goal = try goal.resetting(
            at: Date(timeIntervalSinceReferenceDate: 300),
            originTimeZoneIdentifier: "Asia/Singapore"
        )

        try await store.upsert(
            goal,
            id: goal.id.uuidString,
            in: .savingsGoals
        )
        let loaded = try await store.fetch(
            SavingsGoal.self,
            id: goal.id.uuidString,
            from: .savingsGoals
        )

        XCTAssertEqual(loaded, goal)
        XCTAssertEqual(loaded?.movements.first?.money.amount, Decimal(string: "12.34"))
        XCTAssertEqual(loaded?.resets.count, 1)
        await store.close()
    }

    func testRecordsSurviveCloseAndReopenWithCorrectKey() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let sgd = try CurrencyCode("SGD")
        let account = LedgerAccount(
            name: "Private Daily Account",
            kind: .asset,
            currency: sgd
        )

        var store: EncryptedRecordStore? = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        try await store?.upsert(
            account,
            id: account.id.uuidString,
            in: .accounts
        )
        await store?.close()
        store = nil

        let reopened = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let loaded = try await reopened.fetch(
            LedgerAccount.self,
            id: account.id.uuidString,
            from: .accounts
        )

        XCTAssertEqual(loaded, account)
        await reopened.close()
    }

    func testWrongKeyCannotReadExistingDatabase() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let account = LedgerAccount(name: "Secret", kind: .asset)
        try await store.upsert(account, id: account.id.uuidString, in: .accounts)
        await store.close()

        XCTAssertThrowsError(
            try EncryptedRecordStore(
                databaseURL: fixture.databaseURL,
                key: Data(repeating: 0x22, count: 32)
            )
        )
    }

    func testDatabaseFileDoesNotExposeStoredPlaintext() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let marker = "MONEYUP-PLAINTEXT-MUST-NOT-APPEAR"
        let account = LedgerAccount(name: marker, kind: .asset)
        try await store.upsert(account, id: account.id.uuidString, in: .accounts)
        await store.close()

        let databaseBytes = try Data(contentsOf: fixture.databaseURL)
        let markerBytes = Data(marker.utf8)

        XCTAssertFalse(databaseBytes.starts(with: Data("SQLite format 3".utf8)))
        XCTAssertNil(databaseBytes.range(of: markerBytes))
    }

    func testBalancedJournalEntryRoundTripsWithoutLosingDecimals() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let entry = try JournalEntry(
            kind: .expense,
            payee: "Lunch",
            postings: [
                Posting(
                    accountID: UUID(),
                    money: try Money(Decimal(string: "12.34")!, currency: sgd)
                ),
                Posting(
                    accountID: UUID(),
                    money: try Money(Decimal(string: "-12.34")!, currency: sgd)
                )
            ]
        )

        try await store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        let loaded = try await store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )

        XCTAssertEqual(loaded, [entry])
        await store.close()
    }

    func testJournalPagesUseHalfOpenDateBoundsAndStableKeysetOrdering() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let jan2 = Date(timeIntervalSince1970: 1_735_776_000)
        let jan1 = jan2.addingTimeInterval(-86_400)
        let firstAtJan2 = try makeExpenseEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            occurredAt: jan2,
            amount: 1
        )
        let secondAtJan2 = try makeExpenseEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            occurredAt: jan2,
            amount: 2
        )
        let entryAtJan1 = try makeExpenseEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            occurredAt: jan1,
            amount: 3
        )
        try await store.write(
            try [firstAtJan2, secondAtJan2, entryAtJan1].map {
                try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
            }
        )

        let firstPage = try await store.fetchJournalEntryPage(limit: 2)
        XCTAssertEqual(firstPage.entries.map(\.id), [secondAtJan2.id, firstAtJan2.id])
        XCTAssertNotNil(firstPage.nextCursor)

        let secondPage = try await store.fetchJournalEntryPage(
            after: firstPage.nextCursor,
            limit: 2
        )
        XCTAssertEqual(secondPage.entries.map(\.id), [entryAtJan1.id])
        XCTAssertNil(secondPage.nextCursor)

        let bounded = try await store.fetchJournalEntryPage(
            startDate: jan2,
            endDateExclusive: jan2.addingTimeInterval(86_400),
            limit: 10
        )
        XCTAssertEqual(bounded.entries.map(\.id), [secondAtJan2.id, firstAtJan2.id])
        await store.close()
    }

    func testJournalOriginDayIndexDrivesExactPagesAndPostingEvents() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-03T12:00:00Z")
        )
        let origin = try TransactionOriginContext(
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "Pacific/Kiritimati",
            utcOffsetSeconds: 50_400,
            dayKey: 20260204
        )
        let entry = try makeExpenseEntry(
            occurredAt: occurredAt,
            amount: 7,
            originContext: origin
        )
        try await store.upsert(entry, id: entry.id.uuidString, in: .journalEntries)

        let wrongDay = try await store.fetchJournalEntryPage(
            startDayKey: 20260203,
            endDayKeyExclusive: 20260204,
            limit: 10
        )
        XCTAssertTrue(wrongDay.entries.isEmpty)
        let exactDay = try await store.fetchJournalEntryPage(
            startDayKey: 20260204,
            endDayKeyExclusive: 20260205,
            limit: 10
        )
        XCTAssertEqual(exactDay.entries, [entry])

        let events = try await store.fetchJournalPostingEvents(
            originDayKeyRange: 20260204..<20260205
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.originDayKey == 20260204 })
        let existing = try await store.existingJournalEntryIDs(
            in: Set([entry.id, UUID()])
        )
        XCTAssertEqual(existing, Set([entry.id]))
        await store.close()
    }

    func testSnapshotRestoreRebuildsTheJournalDateIndex() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let entry = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            amount: 42
        )
        try await store.upsert(entry, id: entry.id.uuidString, in: .journalEntries)
        let snapshot = try await store.snapshot()
        try await store.remove(id: entry.id.uuidString, from: .journalEntries)

        try await store.restore(snapshot)
        let page = try await store.fetchJournalEntryPage(limit: 10)
        XCTAssertEqual(page.entries, [entry])
        let accountIDs = Set(entry.postings.map(\.accountID))
        let ledger = try await store.journalLedgerIndex(validAccountIDs: accountIDs)
        XCTAssertEqual(ledger.entryCount, 1)
        let sgd = try CurrencyCode("SGD")
        XCTAssertEqual(
            ledger.balances[entry.postings[0].accountID]?[sgd]?.amount,
            42
        )
        await store.close()
    }

    func testNormalizedLedgerIndexQuarantinesTheWholeOrphanEntry() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let accountID = UUID()
        let missingCategoryID = UUID()
        let entry = try JournalEntry(
            kind: .expense,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            postings: [
                Posting(
                    accountID: accountID,
                    money: try Money(-12.34, currency: sgd)
                ),
                Posting(
                    accountID: missingCategoryID,
                    money: try Money(12.34, currency: sgd)
                )
            ],
            sourceSystem: "Import",
            sourceFingerprint: "orphan-source-1"
        )
        try await store.upsert(entry, id: entry.id.uuidString, in: .journalEntries)

        let snapshot = try await store.journalLedgerIndex(
            validAccountIDs: Set([accountID])
        )
        XCTAssertEqual(snapshot.entryCount, 0)
        XCTAssertTrue(snapshot.balances.isEmpty)
        XCTAssertEqual(snapshot.referenceCounts[accountID, default: 0], 0)
        XCTAssertEqual(snapshot.invalidRelationshipEntryIDs, Set([entry.id]))
        let containsFingerprint = try await store.containsJournalEntry(
            sourceFingerprint: "orphan-source-1"
        )
        XCTAssertTrue(containsFingerprint)
        let fingerprints = try await store.journalSourceFingerprints()
        XCTAssertEqual(fingerprints, Set(["orphan-source-1"]))

        let events = try await store.fetchJournalPostingEvents(
            startDate: entry.occurredAt.addingTimeInterval(-1),
            endDateExclusive: entry.occurredAt.addingTimeInterval(1),
            excludingEntryIDs: snapshot.invalidRelationshipEntryIDs
        )
        XCTAssertTrue(events.isEmpty)
        await store.close()
    }

    func testNormalizedLedgerIndexQuarantinesWholeCurrencyMismatchEntry() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let accountID = UUID()
        let categoryID = UUID()
        let healthy = try JournalEntry(
            kind: .expense,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            postings: [
                Posting(
                    accountID: accountID,
                    money: try Money(-5, currency: sgd)
                ),
                Posting(
                    accountID: categoryID,
                    money: try Money(5, currency: sgd)
                )
            ]
        )
        let mismatched = try JournalEntry(
            kind: .expense,
            occurredAt: healthy.occurredAt.addingTimeInterval(1),
            postings: [
                Posting(
                    accountID: accountID,
                    money: try Money(-12, currency: usd)
                ),
                Posting(
                    accountID: categoryID,
                    money: try Money(12, currency: usd)
                )
            ]
        )
        try await store.write([
            try RecordWrite(
                healthy,
                id: healthy.id.uuidString,
                in: .journalEntries
            ),
            try RecordWrite(
                mismatched,
                id: mismatched.id.uuidString,
                in: .journalEntries
            )
        ])

        let snapshot = try await store.journalLedgerIndex(
            validAccountIDs: Set([accountID, categoryID]),
            expectedAccountCurrencies: [accountID: sgd]
        )

        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertEqual(snapshot.invalidRelationshipEntryIDs, Set([mismatched.id]))
        XCTAssertEqual(snapshot.referenceCounts[accountID], 1)
        XCTAssertEqual(snapshot.referenceCounts[categoryID], 1)
        XCTAssertEqual(snapshot.balances[accountID]?[sgd]?.amount, -5)
        XCTAssertNil(snapshot.balances[accountID]?[usd])
        XCTAssertEqual(snapshot.balances[categoryID]?[sgd]?.amount, 5)
        XCTAssertNil(snapshot.balances[categoryID]?[usd])

        let events = try await store.fetchJournalPostingEvents(
            startDate: healthy.occurredAt.addingTimeInterval(-1),
            endDateExclusive: mismatched.occurredAt.addingTimeInterval(1),
            excludingEntryIDs: snapshot.invalidRelationshipEntryIDs
        )
        XCTAssertEqual(Set(events.map(\.entryID)), Set([healthy.id]))
        await store.close()
    }

    func testTenThousandEntryJournalCanBeReadInBoundedPagesWithoutLoss() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        var writes: [RecordWrite] = []
        writes.reserveCapacity(10_000)
        for offset in 0..<10_000 {
            let entry = try makeExpenseEntry(
                occurredAt: start.addingTimeInterval(TimeInterval(offset)),
                amount: Decimal((offset % 100) + 1),
                firstAccountID: firstAccountID,
                secondAccountID: secondAccountID
            )
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
        }
        try await store.write(writes)

        var cursor: JournalEntryPageCursor?
        var seen = Set<UUID>()
        var previousDate = Date.distantFuture
        repeat {
            let page = try await store.fetchJournalEntryPage(
                after: cursor,
                limit: 137
            )
            XCTAssertLessThanOrEqual(page.entries.count, 137)
            for entry in page.entries {
                XCTAssertLessThanOrEqual(entry.occurredAt, previousDate)
                XCTAssertTrue(seen.insert(entry.id).inserted)
                previousDate = entry.occurredAt
            }
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(seen.count, 10_000)

        let diagnostics = try await store.journalIndexDiagnostics()
        XCTAssertEqual(diagnostics.journalRecordCount, 10_000)
        XCTAssertEqual(diagnostics.indexedEntryCount, 10_000)
        XCTAssertEqual(diagnostics.indexedPostingCount, 20_000)

        let selectedEvents = try await store.fetchJournalPostingEvents(
            startDate: start.addingTimeInterval(100),
            endDateExclusive: start.addingTimeInterval(110)
        )
        XCTAssertEqual(selectedEvents.count, 20)
        XCTAssertTrue(selectedEvents.allSatisfy {
            $0.occurredAt >= start.addingTimeInterval(100)
                && $0.occurredAt < start.addingTimeInterval(110)
        })

        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: Set([firstAccountID, secondAccountID])
        )
        let sgd = try CurrencyCode("SGD")
        XCTAssertEqual(ledger.entryCount, 10_000)
        XCTAssertEqual(
            ledger.balances[firstAccountID]?[sgd]?.amount,
            Decimal(505_000)
        )
        let ledgerReadDiagnostics = await store.lastJournalLedgerReadDiagnostics()
        XCTAssertEqual(ledgerReadDiagnostics.invalidEntryIDsRead, 0)
        XCTAssertEqual(ledgerReadDiagnostics.quarantinedPostingRowsRead, 0)
        XCTAssertEqual(ledgerReadDiagnostics.referenceAggregateRowsRead, 2)

        // A routine save reads no prior posting rows and only the two compact
        // balance rows it changes; it cannot regress to a 10,000-row scan.
        let appended = try makeExpenseEntry(
            occurredAt: start.addingTimeInterval(20_000),
            amount: 1,
            firstAccountID: firstAccountID,
            secondAccountID: secondAccountID
        )
        try await store.upsert(
            appended,
            id: appended.id.uuidString,
            in: .journalEntries
        )
        let writeDiagnostics = await store.lastJournalWriteDiagnostics()
        XCTAssertEqual(writeDiagnostics.priorPostingRowsRead, 0)
        XCTAssertEqual(writeDiagnostics.compactBalanceRowsRead, 2)
        XCTAssertEqual(writeDiagnostics.journalEntriesChanged, 1)
        _ = try await store.journalLedgerIndex(
            validAccountIDs: Set([firstAccountID, secondAccountID])
        )
        let refreshedReadDiagnostics = await store.lastJournalLedgerReadDiagnostics()
        XCTAssertEqual(refreshedReadDiagnostics.quarantinedPostingRowsRead, 0)
        XCTAssertEqual(refreshedReadDiagnostics.referenceAggregateRowsRead, 2)
        await store.close()
    }

    func testBatchWriteRollsBackEveryRecordWhenOneRecordFails() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let account = LedgerAccount(name: "Atomic", kind: .asset)
        let valid = try RecordWrite(
            account,
            id: account.id.uuidString,
            in: .accounts
        )
        let invalid = RecordWrite(
            collection: .accounts,
            id: "empty-payload",
            payload: Data()
        )
        let draftMarker = "draft-must-survive-rollback"
        try await store.upsert(
            draftMarker,
            id: "current",
            in: .quickLogDrafts
        )

        do {
            try await store.write(
                [valid, invalid],
                removing: [
                    RecordDeletion(id: "current", from: .quickLogDrafts)
                ]
            )
            XCTFail("Expected the payload constraint to reject the batch")
        } catch {
            // The first write must have been rolled back with the second one.
        }
        let count = try await store.count(in: .accounts)
        XCTAssertEqual(count, 0)
        let retainedDraft = try await store.fetch(
            String.self,
            id: "current",
            from: .quickLogDrafts
        )
        XCTAssertEqual(retainedDraft, draftMarker)
        await store.close()
    }

    func testRecordCountSnapshotIncludesEveryCollectionWithoutPayloads() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let account = LedgerAccount(name: "Private account name", kind: .asset)
        try await store.upsert(
            account,
            id: account.id.uuidString,
            in: .accounts
        )
        try await store.upsert(
            "private draft payload",
            id: "current",
            in: .quickLogDrafts
        )

        let snapshot = try await store.recordCountSnapshot()

        XCTAssertEqual(snapshot.schemaVersion, EncryptedRecordStore.currentSchemaVersion)
        XCTAssertEqual(snapshot.storedRecordCounts.count, RecordCollection.allCases.count)
        XCTAssertEqual(snapshot.count(in: .accounts), 1)
        XCTAssertEqual(snapshot.count(in: .quickLogDrafts), 1)
        XCTAssertEqual(snapshot.count(in: .journalEntries), 0)
        XCTAssertFalse(snapshot.storedRecordCounts.keys.contains("Private account name"))
        await store.close()
    }

    func testStorageMetricsMatchExactSnapshotByteTotals() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let account = LedgerAccount(name: "Private account name", kind: .asset)
        try await store.upsert(
            account,
            id: account.id.uuidString,
            in: .accounts
        )
        try await store.upsert(
            "private draft payload",
            id: "current",
            in: .quickLogDrafts
        )

        let metrics = try await store.storageMetrics()
        let snapshot = try await store.snapshot()
        XCTAssertEqual(metrics.recordCount, snapshot.records.count)
        XCTAssertEqual(
            metrics.payloadByteCount,
            snapshot.records.reduce(0) { $0 + $1.payload.count }
        )
        XCTAssertEqual(
            metrics.recordIDByteCount,
            snapshot.records.reduce(0) { $0 + $1.recordID.utf8.count }
        )
        XCTAssertEqual(
            metrics.collectionByteCount,
            snapshot.records.reduce(0) { $0 + $1.collection.utf8.count }
        )
        await store.close()
    }

    func testJournalBalanceOverflowRollsBackRecordAndIndexAtomically() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let accountID = UUID()
        let categoryID = UUID()
        let sgd = try CurrencyCode("SGD")
        let huge = try XCTUnwrap(
            Decimal(
                string: "9e127",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let first = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            amount: huge,
            firstAccountID: accountID,
            secondAccountID: categoryID
        )
        let second = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001),
            amount: huge,
            firstAccountID: accountID,
            secondAccountID: categoryID
        )
        try await store.upsert(
            first,
            id: first.id.uuidString,
            in: .journalEntries
        )
        let before = try await store.snapshot()

        do {
            try await store.upsert(
                second,
                id: second.id.uuidString,
                in: .journalEntries
            )
            XCTFail("Expected the materialized balance to overflow")
        } catch {
            XCTAssertEqual(error as? DecimalCalculationError, .overflow)
        }

        let after = try await store.snapshot()
        XCTAssertEqual(after.records, before.records)
        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: Set([accountID, categoryID])
        )
        XCTAssertEqual(ledger.entryCount, 1)
        XCTAssertEqual(
            ledger.balances[accountID]?[sgd]?.amount,
            huge
        )
        await store.close()
    }

    func testWriteRollbackFailureClosesConnectionAndReopenRecoversOldSnapshot() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let original = LedgerAccount(name: "Original", kind: .asset)
        try await store.upsert(
            original,
            id: original.id.uuidString,
            in: .accounts
        )
        let before = try await store.snapshot()
        let accountID = UUID()
        let categoryID = UUID()
        let huge = try XCTUnwrap(
            Decimal(
                string: "9e127",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let first = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            amount: huge,
            firstAccountID: accountID,
            secondAccountID: categoryID
        )
        let second = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001),
            amount: huge,
            firstAccountID: accountID,
            secondAccountID: categoryID
        )
        await store.failNextWriteRollbackForTesting()

        do {
            try await store.write([
                try RecordWrite(
                    first,
                    id: first.id.uuidString,
                    in: .journalEntries
                ),
                try RecordWrite(
                    second,
                    id: second.id.uuidString,
                    in: .journalEntries
                )
            ])
            XCTFail("Expected an indeterminate write rollback failure")
        } catch PersistenceError.transactionStateIndeterminate {
            // Closing the connection is the recovery boundary.
        }

        let reopened = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let recovered = try await reopened.snapshot()
        XCTAssertEqual(recovered.records, before.records)
        let ledger = try await reopened.journalLedgerIndex(
            validAccountIDs: Set([original.id])
        )
        XCTAssertEqual(ledger.entryCount, 0)
        await reopened.close()
    }

    func testLifecycleBatchRollsBackRepointedEntryAuditAndSourceDeletionTogether() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let source = LedgerAccount(name: "Old wallet", kind: .asset, currency: sgd)
        let target = LedgerAccount(name: "Daily wallet", kind: .asset, currency: sgd)
        let category = LedgerAccount(name: "Food", kind: .expense)
        let original = try TransactionFactory.expense(
            amount: try Money(12, currency: sgd),
            paidFrom: source.id,
            category: category.id,
            payee: "Cafe"
        )
        let repointed = try JournalEntry(
            id: original.id,
            kind: original.kind,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            payee: original.payee,
            note: original.note,
            postings: original.postings.map {
                Posting(
                    id: $0.id,
                    accountID: $0.accountID == source.id ? target.id : $0.accountID,
                    money: $0.money,
                    memo: $0.memo
                )
            }
        )
        let audit = LedgerAccountLifecycleAudit(
            action: .merged,
            before: source,
            after: target,
            targetID: target.id,
            affectedJournalEntryIDs: [original.id]
        )
        for account in [source, target, category] {
            try await store.upsert(account, id: account.id.uuidString, in: .accounts)
        }
        try await store.upsert(
            original,
            id: original.id.uuidString,
            in: .journalEntries
        )

        let invalid = RecordWrite(
            collection: .accountLifecycleAudit,
            id: "invalid-empty-payload",
            payload: Data()
        )
        do {
            try await store.write(
                [
                    try RecordWrite(
                        repointed,
                        id: repointed.id.uuidString,
                        in: .journalEntries
                    ),
                    try RecordWrite(
                        original,
                        id: "\(original.id.uuidString)-before-merge",
                        in: .journalEntryRevisions
                    ),
                    try RecordWrite(
                        audit,
                        id: audit.id.uuidString,
                        in: .accountLifecycleAudit
                    ),
                    invalid
                ],
                removing: [
                    RecordDeletion(id: source.id.uuidString, from: .accounts)
                ]
            )
            XCTFail("Expected the invalid audit payload to roll back the lifecycle batch")
        } catch {
            // Expected: no partially repointed book may escape the transaction.
        }

        let storedSource = try await store.fetch(
            LedgerAccount.self,
            id: source.id.uuidString,
            from: .accounts
        )
        let storedEntry = try await store.fetch(
            JournalEntry.self,
            id: original.id.uuidString,
            from: .journalEntries
        )
        XCTAssertEqual(storedSource, source)
        XCTAssertEqual(storedEntry, original)
        let revisionCount = try await store.count(in: .journalEntryRevisions)
        let auditCount = try await store.count(in: .accountLifecycleAudit)
        XCTAssertEqual(revisionCount, 0)
        XCTAssertEqual(auditCount, 0)
        await store.close()
    }

    func testEncryptedQuickLogDraftCollectionRoundTripsAndClears() async throws {
        struct DraftRecord: Codable, Equatable, Sendable {
            let amountText: String
            let note: String
        }

        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let draft = DraftRecord(amountText: "12.34", note: "unfinished lunch")

        try await store.upsert(draft, id: "current", in: .quickLogDrafts)
        let loaded = try await store.fetch(
            DraftRecord.self,
            id: "current",
            from: .quickLogDrafts
        )
        XCTAssertEqual(loaded, draft)

        let account = LedgerAccount(name: "Committed with draft clear", kind: .asset)
        try await store.write(
            [try RecordWrite(account, id: account.id.uuidString, in: .accounts)],
            removing: [RecordDeletion(id: "current", from: .quickLogDrafts)]
        )
        let cleared = try await store.fetch(
            DraftRecord.self,
            id: "current",
            from: .quickLogDrafts
        )
        XCTAssertNil(cleared)
        let committed = try await store.fetch(
            LedgerAccount.self,
            id: account.id.uuidString,
            from: .accounts
        )
        XCTAssertEqual(committed, account)
        await store.close()
    }

    func testSnapshotRestoreReplacesAllRecordsAtomically() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let original = LedgerAccount(name: "Original", kind: .asset)
        try await store.upsert(original, id: original.id.uuidString, in: .accounts)
        let snapshot = try await store.snapshot()

        let later = LedgerAccount(name: "Later", kind: .asset)
        try await store.upsert(later, id: later.id.uuidString, in: .accounts)
        let recordCount = try await store.count(in: .accounts)
        XCTAssertEqual(recordCount, 2)

        try await store.restore(snapshot)
        let restored = try await store.fetchAll(LedgerAccount.self, from: .accounts)
        XCTAssertEqual(restored, [original])
        await store.close()
    }

    func testSnapshotRestoreCancellationRollsBackUnlessRecoveryIsUninterruptible() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let original = LedgerAccount(name: "Original", kind: .asset)
        try await store.upsert(original, id: original.id.uuidString, in: .accounts)
        let originalSnapshot = try await store.snapshot()
        let later = LedgerAccount(name: "Later", kind: .asset)
        try await store.upsert(later, id: later.id.uuidString, in: .accounts)
        let candidate = try await store.snapshot()
        try await store.restore(originalSnapshot)

        let cancellationGate = RestoreStartGate()
        let canceledRestore = Task {
            await cancellationGate.suspend()
            try await store.restore(candidate)
        }
        await cancellationGate.waitUntilReached()
        canceledRestore.cancel()
        await cancellationGate.release()
        do {
            try await canceledRestore.value
            XCTFail("Expected a canceled candidate restore to roll back")
        } catch is CancellationError {
            // Cancellation is checked before BEGIN and throughout replacement.
        }
        let afterCancellation = try await store.fetchAll(
            LedgerAccount.self,
            from: .accounts
        )
        XCTAssertEqual(afterCancellation, [original])

        let recoveryGate = RestoreStartGate()
        let recoveryRestore = Task {
            await recoveryGate.suspend()
            try await store.restore(candidate, observesCancellation: false)
        }
        await recoveryGate.waitUntilReached()
        recoveryRestore.cancel()
        await recoveryGate.release()
        try await recoveryRestore.value
        let afterRecovery = try await store.fetchAll(
            LedgerAccount.self,
            from: .accounts
        )
        XCTAssertEqual(
            Set(afterRecovery.map(\.id)),
            Set([original.id, later.id])
        )
        await store.close()
    }

    func testCancelledJournalRecordWriteCannotLoseItsNormalizedIndex() async throws {
        let entry = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            amount: 12
        )
        let gate = RestoreStartGate()
        let creation = Task {
            await gate.suspend()
            return try RecordWrite(
                entry,
                id: entry.id.uuidString,
                in: .journalEntries
            )
        }

        await gate.waitUntilReached()
        creation.cancel()
        await gate.release()
        do {
            _ = try await creation.value
            XCTFail("Expected cancelled journal index derivation to fail")
        } catch is CancellationError {
            // A caller cannot hand a valid payload with a missing index to SQL.
        }
    }

    func testCancelledRecoveringJournalFetchCannotReturnATruncatedSuccess() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let entry = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            amount: 12
        )
        try await store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        let gate = RestoreStartGate()
        let fetch = Task {
            await gate.suspend()
            return try await store.fetchAllRecovering(
                JournalEntry.self,
                from: .journalEntries
            )
        }

        await gate.waitUntilReached()
        fetch.cancel()
        await gate.release()
        do {
            _ = try await fetch.value
            XCTFail("Expected recovering fetch to preserve cancellation")
        } catch is CancellationError {
            // Cancellation is not misreported as a malformed persisted row.
        }
        await store.close()
    }

    func testCancelledJournalPageCannotReturnATruncatedSuccess() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let entry = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            amount: 12
        )
        try await store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        let gate = RestoreStartGate()
        let fetch = Task {
            await gate.suspend()
            return try await store.fetchJournalEntryPage(limit: 10)
        }

        await gate.waitUntilReached()
        fetch.cancel()
        await gate.release()
        do {
            _ = try await fetch.value
            XCTFail("Expected journal page decode to preserve cancellation")
        } catch is CancellationError {
            // History and mutation callers cannot observe an incomplete page.
        }
        await store.close()
    }

    func testNormalWriteRejectsAnUnindexedJournalPayloadBeforeCommit() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let recordID = UUID().uuidString
        let invalid = RecordWrite(
            collection: .journalEntries,
            id: recordID,
            payload: Data("{not-json".utf8)
        )

        do {
            try await store.write([invalid])
            XCTFail("Expected an unindexed journal write to fail closed")
        } catch let error as PersistenceError {
            XCTAssertEqual(
                error,
                .invalidStoredRecord(
                    collection: .journalEntries,
                    recordID: recordID
                )
            )
        }
        let diagnostics = try await store.journalIndexDiagnostics()
        XCTAssertEqual(diagnostics.journalRecordCount, 0)
        XCTAssertEqual(diagnostics.indexedEntryCount, 0)
        XCTAssertEqual(diagnostics.indexedPostingCount, 0)
        await store.close()
    }

    func testInvalidSnapshotLeavesExistingRecordsUntouched() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let original = LedgerAccount(name: "Must survive", kind: .asset)
        try await store.upsert(original, id: original.id.uuidString, in: .accounts)
        let invalid = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                StoredRecordSnapshot(
                    collection: RecordCollection.accounts.rawValue,
                    recordID: "empty",
                    payload: Data(),
                    updatedAt: Date().timeIntervalSince1970
                )
            ]
        )

        do {
            try await store.restore(invalid)
            XCTFail("Expected invalid snapshot to fail")
        } catch {
            // Validation happens before BEGIN/DELETE.
        }
        let retained = try await store.fetchAll(LedgerAccount.self, from: .accounts)
        XCTAssertEqual(retained, [original])
        await store.close()
    }

    func testRestoreRollbackFailureClosesConnectionAndReopenRecoversOldSnapshot() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let original = LedgerAccount(name: "Original", kind: .asset)
        try await store.upsert(
            original,
            id: original.id.uuidString,
            in: .accounts
        )
        let before = try await store.snapshot()
        await store.failNextRestoreRollbackForTesting()

        let accountID = UUID()
        let categoryID = UUID()
        let huge = try XCTUnwrap(
            Decimal(
                string: "9e127",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let first = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            amount: huge,
            firstAccountID: accountID,
            secondAccountID: categoryID
        )
        let second = try makeExpenseEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001),
            amount: huge,
            firstAccountID: accountID,
            secondAccountID: categoryID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: try [first, second].enumerated().map { index, entry in
                StoredRecordSnapshot(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: entry.id.uuidString,
                    payload: try encoder.encode(entry),
                    updatedAt: TimeInterval(index + 1)
                )
            }
        )
        do {
            try await store.restore(candidate)
            XCTFail("Expected an indeterminate rollback failure")
        } catch PersistenceError.restoreTransactionStateIndeterminate {
            // The failed connection is closed rather than exposing a partial
            // in-transaction candidate to later reads or backups.
        }

        let reopened = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let recovered = try await reopened.snapshot()
        XCTAssertEqual(recovered.records, before.records)
        let account = try await reopened.fetch(
            LedgerAccount.self,
            id: original.id.uuidString,
            from: .accounts
        )
        XCTAssertEqual(account, original)
        await reopened.close()
    }

    func testNonpositiveSnapshotSchemaLeavesExistingRecordsUntouched() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let original = LedgerAccount(name: "Must survive", kind: .asset)
        try await store.upsert(original, id: original.id.uuidString, in: .accounts)
        let invalid = DatabaseSnapshot(schemaVersion: 0, records: [])

        do {
            try await store.restore(invalid)
            XCTFail("Expected a nonpositive snapshot schema to fail")
        } catch PersistenceError.invalidSnapshot {
            // Validation happens before BEGIN/DELETE.
        }

        let retained = try await store.fetchAll(LedgerAccount.self, from: .accounts)
        XCTAssertEqual(retained, [original])
        await store.close()
    }

    func testRecoveringFetchQuarantinesOnlyMalformedRows() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let account = LedgerAccount(name: "Readable", kind: .asset)
        try await store.write([
            try RecordWrite(account, id: account.id.uuidString, in: .accounts),
            RecordWrite(
                collection: .accounts,
                id: "malformed",
                payload: Data("{not-json".utf8)
            )
        ])

        let recovered = try await store.fetchAllRecovering(
            LedgerAccount.self,
            from: .accounts
        )
        XCTAssertEqual(recovered.values, [account])
        XCTAssertEqual(recovered.issues.map(\.recordID), ["malformed"])
        await store.close()
    }

    func testUUIDIdentifiedWritesAndRecoveryRejectPhysicalAliases() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let account = LedgerAccount(name: "Aliased", kind: .asset)
        let aliasRecordID = UUID().uuidString

        do {
            _ = try RecordWrite(
                account,
                id: aliasRecordID,
                in: .accounts
            )
            XCTFail("A normal write must reject a payload/key mismatch")
        } catch let error as PersistenceError {
            XCTAssertEqual(
                error,
                .invalidStoredRecord(
                    collection: .accounts,
                    recordID: aliasRecordID
                )
            )
        }

        let snapshot = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [StoredRecordSnapshot(
                collection: RecordCollection.accounts.rawValue,
                recordID: aliasRecordID,
                payload: try JSONEncoder().encode(account),
                updatedAt: Date().timeIntervalSince1970
            )]
        )
        try await store.restore(snapshot)
        let recovered = try await store.fetchAllIdentifiedRecovering(
            LedgerAccount.self,
            from: .accounts
        )

        XCTAssertTrue(recovered.values.isEmpty)
        XCTAssertEqual(recovered.issues, [RecordDecodeIssue(
            collection: .accounts,
            recordID: aliasRecordID
        )])
        let persistedAccountCount = try await store.count(in: .accounts)
        XCTAssertEqual(persistedAccountCount, 1)
        await store.close()
    }

    func testLegacyLowercaseJournalAndReceiptAliasesAreQuarantined() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let entryID = try XCTUnwrap(
            UUID(uuidString: "ABCDEF12-3456-4789-ABCD-EF1234567890")
        )
        let walletID = UUID()
        let categoryID = UUID()
        let entry = try makeExpenseEntry(
            id: entryID,
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            amount: 5,
            firstAccountID: walletID,
            secondAccountID: categoryID
        )
        let attachmentID = try XCTUnwrap(
            UUID(uuidString: "FEDCBA98-7654-4321-ABCD-EF1234567890")
        )
        let attachment = try ReceiptAttachment(
            id: attachmentID,
            entryID: entry.id,
            mediaType: .jpeg,
            data: Data([0xff, 0x01]),
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let aliasedAttachment = try ReceiptAttachment(
            id: attachmentID,
            entryID: entry.id,
            mediaType: .jpeg,
            data: Data([0xff, 0x02]),
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let journalAlias = entryID.uuidString.lowercased()
        let receiptAlias = attachmentID.uuidString.lowercased()

        try await store.restore(DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                StoredRecordSnapshot(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: entryID.uuidString,
                    payload: try JSONEncoder().encode(entry),
                    updatedAt: 1
                ),
                StoredRecordSnapshot(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: journalAlias,
                    payload: try JSONEncoder().encode(entry),
                    updatedAt: 1
                ),
                StoredRecordSnapshot(
                    collection: RecordCollection.receiptAttachments.rawValue,
                    recordID: attachmentID.uuidString,
                    payload: try JSONEncoder().encode(attachment),
                    updatedAt: 1
                ),
                StoredRecordSnapshot(
                    collection: RecordCollection.receiptAttachments.rawValue,
                    recordID: receiptAlias,
                    payload: try JSONEncoder().encode(aliasedAttachment),
                    updatedAt: 1
                )
            ]
        ))
        try await store.installLegacyCaseVariantIndexesForTesting()

        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: Set([walletID, categoryID])
        )
        XCTAssertEqual(ledger.entryCount, 0)
        XCTAssertTrue(ledger.balances.isEmpty)
        XCTAssertEqual(ledger.referenceCounts[walletID] ?? 0, 0)
        XCTAssertEqual(ledger.referenceCounts[categoryID] ?? 0, 0)
        XCTAssertTrue(ledger.issues.contains(RecordDecodeIssue(
            collection: .journalEntries,
            recordID: journalAlias
        )))
        XCTAssertTrue(ledger.issues.contains(RecordDecodeIssue(
            collection: .journalEntries,
            recordID: entryID.uuidString
        )))
        XCTAssertEqual(ledger.invalidRelationshipEntryIDs, [entryID])
        let page = try await store.fetchJournalEntryPage(limit: 10)
        XCTAssertEqual(page.entries, [entry])
        XCTAssertEqual(page.issues, [RecordDecodeIssue(
            collection: .journalEntries,
            recordID: journalAlias
        )])

        let receiptIndex = try await store.receiptAttachmentIndexSnapshot()
        XCTAssertEqual(receiptIndex.metadata, [ReceiptAttachmentMetadata(attachment)])
        XCTAssertEqual(receiptIndex.issues, [RecordDecodeIssue(
            collection: .receiptAttachments,
            recordID: receiptAlias
        )])
        let selected = try await store.receiptAttachment(id: attachmentID)
        XCTAssertEqual(selected?.data, attachment.data)
        do {
            _ = try await store.receiptAttachmentIDs(entryID: entryID)
            XCTFail("A legacy physical alias must make cascade deletion fail closed")
        } catch let error as PersistenceError {
            XCTAssertEqual(
                error,
                .invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: receiptAlias
                )
            )
        }
        let journalPhysicalCount = try await store.count(in: .journalEntries)
        let receiptPhysicalCount = try await store.count(in: .receiptAttachments)
        XCTAssertEqual(journalPhysicalCount, 2)
        XCTAssertEqual(receiptPhysicalCount, 2)
        await store.close()
    }

    func testTargetedJournalRecoveryBatchesIDsAndChecksPayloadIdentity() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let walletID = UUID()
        let categoryID = UUID()
        let entries = try (0..<405).map { offset in
            try TransactionFactory.expense(
                amount: try Money(1, currency: sgd),
                paidFrom: walletID,
                category: categoryID,
                occurredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset))
            )
        }
        let malformedID = UUID()
        let mismatchedPhysicalID = UUID()
        let mismatchedPayload = try TransactionFactory.expense(
            amount: try Money(2, currency: sgd),
            paidFrom: walletID,
            category: categoryID
        )
        let writes = try entries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }
        try await store.write(writes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let validSnapshot = try await store.snapshot()
        let corruptedSnapshot = DatabaseSnapshot(
            schemaVersion: validSnapshot.schemaVersion,
            createdAt: validSnapshot.createdAt,
            records: validSnapshot.records + [
                StoredRecordSnapshot(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: malformedID.uuidString,
                    payload: Data("{not-json".utf8),
                    updatedAt: 1_000
                ),
                StoredRecordSnapshot(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: mismatchedPhysicalID.uuidString,
                    payload: try encoder.encode(mismatchedPayload),
                    updatedAt: 1_001
                )
            ]
        )
        try await store.restore(corruptedSnapshot)
        let missingID = UUID()

        let recovered = try await store.fetchJournalEntriesRecovering(
            ids: Set(entries.map(\.id)).union([
                malformedID,
                mismatchedPhysicalID,
                missingID
            ])
        )

        XCTAssertEqual(Set(recovered.values.map(\.id)), Set(entries.map(\.id)))
        XCTAssertEqual(
            Set(recovered.issues.map(\.recordID)),
            Set([malformedID.uuidString, mismatchedPhysicalID.uuidString])
        )
        await store.close()
    }

    func testVersion040RecordsDecodeAfterInPlaceUpdateWithoutRewriting() async throws {
        struct LegacyProfile: Codable, Sendable {
            let baseCurrency: CurrencyCode
            let createdAt: Date
            let lockWhenBackgrounded: Bool
        }

        struct LegacyEntry: Codable, Sendable {
            let id: UUID
            let kind: JournalEntryKind
            let occurredAt: Date
            let createdAt: Date
            let payee: String?
            let note: String?
            let postings: [Posting]
        }

        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let profile = LegacyProfile(
            baseCurrency: sgd,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            lockWhenBackgrounded: true
        )
        let entry = LegacyEntry(
            id: UUID(),
            kind: .expense,
            occurredAt: Date(timeIntervalSinceReferenceDate: 200),
            createdAt: Date(timeIntervalSinceReferenceDate: 201),
            payee: "Legacy lunch",
            note: nil,
            postings: [
                Posting(
                    accountID: UUID(),
                    money: try Money(12.34, currency: sgd)
                ),
                Posting(
                    accountID: UUID(),
                    money: try Money(-12.34, currency: sgd)
                )
            ]
        )
        try await store.write([
            try RecordWrite(
                profile,
                id: UserProfile.primaryRecordID,
                in: .profile
            ),
            try RecordWrite(
                entry,
                id: entry.id.uuidString,
                in: .journalEntries
            )
        ])
        await store.close()

        let reopened = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let upgradedProfile = try await reopened.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        let upgradedEntry = try await reopened.fetch(
            JournalEntry.self,
            id: entry.id.uuidString,
            from: .journalEntries
        )

        XCTAssertEqual(upgradedProfile?.baseCurrency, sgd)
        XCTAssertEqual(upgradedProfile?.autoLockDelay, 60)
        XCTAssertEqual(upgradedProfile?.allowLockedQuickCapture, true)
        XCTAssertEqual(upgradedEntry?.id, entry.id)
        XCTAssertEqual(upgradedEntry?.payee, "Legacy lunch")
        XCTAssertNil(upgradedEntry?.sourceSystem)
        XCTAssertNil(upgradedEntry?.revisedAt)
        XCTAssertEqual(upgradedEntry?.originContext.wasInferred, true)
        XCTAssertEqual(upgradedEntry?.originContext.timeZoneIdentifier, "UTC")
        await reopened.close()
    }

    func testReceiptAttachmentSurvivesSnapshotRestoreAndRemainsSeparate() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sgd = try CurrencyCode("SGD")
        let entry = try JournalEntry(
            kind: .expense,
            postings: [
                Posting(accountID: UUID(), money: try Money(5, currency: sgd)),
                Posting(accountID: UUID(), money: try Money(-5, currency: sgd))
            ]
        )
        let attachment = try ReceiptAttachment(
            entryID: entry.id,
            mediaType: .png,
            data: Data([0x89, 0x50, 0x4e, 0x47, 0x01])
        )
        try await store.upsert(entry, id: entry.id.uuidString, in: .journalEntries)
        try await store.upsert(
            attachment,
            id: attachment.id.uuidString,
            in: .receiptAttachments
        )
        let snapshot = try await store.snapshot()
        try await store.removeAll(from: .receiptAttachments)
        try await store.removeAll(from: .journalEntries)
        try await store.restore(snapshot)

        let restored = try await store.fetch(
            ReceiptAttachment.self,
            id: attachment.id.uuidString,
            from: .receiptAttachments
        )

        XCTAssertEqual(restored, attachment)
        let journalCount = try await store.count(in: .journalEntries)
        XCTAssertEqual(journalCount, 1)
        XCTAssertEqual(restored?.entryID, entry.id)
        await store.close()
    }

    func testReceiptIndexListsLargeLibraryWithoutDecodingBlobs() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let entryID = UUID()
        let attachments = try (0..<250).map { index in
            try ReceiptAttachment(
                entryID: entryID,
                mediaType: .jpeg,
                data: Data(repeating: UInt8(index % 251), count: 1_024),
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index + 1))
            )
        }
        try await store.write(
            try attachments.map {
                try RecordWrite($0, id: $0.id.uuidString, in: .receiptAttachments)
            }
        )

        let index = try await store.receiptAttachmentIndexSnapshot()
        let indexDiagnostics = await store.lastReceiptAttachmentReadDiagnostics()

        XCTAssertEqual(index.metadata.count, attachments.count)
        XCTAssertTrue(index.issues.isEmpty)
        XCTAssertEqual(indexDiagnostics.metadataRowsRead, attachments.count)
        XCTAssertEqual(indexDiagnostics.blobPayloadsDecoded, 0)

        let selected = try await store.receiptAttachment(id: attachments[137].id)
        let selectedDiagnostics = await store.lastReceiptAttachmentReadDiagnostics()
        XCTAssertEqual(selected, attachments[137])
        XCTAssertEqual(selectedDiagnostics.metadataRowsRead, 1)
        XCTAssertEqual(selectedDiagnostics.blobPayloadsDecoded, 1)
        await store.close()
    }

    func testReceiptRelinkIsAtomicAndUsesEntryIndex() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let sourceEntryID = UUID()
        let destinationEntryID = UUID()
        let attachment = try ReceiptAttachment(
            entryID: sourceEntryID,
            mediaType: .png,
            data: Data([0x89, 0x50, 0x4e, 0x47, 0x01])
        )
        try await store.upsert(
            attachment,
            id: attachment.id.uuidString,
            in: .receiptAttachments
        )

        try await store.write(
            [],
            relinkingReceiptAttachments: ReceiptAttachmentRelink(
                sourceEntryID: sourceEntryID,
                destinationEntryID: destinationEntryID
            )
        )

        let sourceIDs = try await store.receiptAttachmentIDs(entryID: sourceEntryID)
        let destinationIDs = try await store.receiptAttachmentIDs(
            entryID: destinationEntryID
        )
        XCTAssertTrue(sourceIDs.isEmpty)
        XCTAssertEqual(destinationIDs, [attachment.id])
        let relinked = try await store.receiptAttachment(id: attachment.id)
        XCTAssertEqual(relinked?.entryID, destinationEntryID)
        XCTAssertEqual(relinked?.data, attachment.data)
        await store.close()
    }

    func testMalformedReceiptPayloadIsQuarantinedByMetadataIndex() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let malformedID = UUID().uuidString
        try await store.restore(
            DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [
                    StoredRecordSnapshot(
                        collection: RecordCollection.receiptAttachments.rawValue,
                        recordID: malformedID,
                        payload: Data("{\"not\":\"an attachment\"}".utf8),
                        updatedAt: 1
                    )
                ]
            )
        )

        let index = try await store.receiptAttachmentIndexSnapshot()
        XCTAssertTrue(index.metadata.isEmpty)
        XCTAssertEqual(index.issues.map(\.recordID), [malformedID])
        let selected = try await store.receiptAttachment(
            id: UUID(uuidString: malformedID)!
        )
        XCTAssertNil(selected)
        await store.close()
    }

    func testInvestmentHistorySnapshotPersistsAcrossReopen() async throws {
        let fixture = try TemporaryDatabaseFixture()
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let rateDate = Date(timeIntervalSinceReferenceDate: 100)
        let rateID = UUID()
        let evidence = try NetWorthConversionEvidence(
            source: try Money(100, currency: usd),
            appliedRate: Decimal(string: "1.35")!,
            rateID: rateID,
            effectiveDayKey: 20010411,
            usedInverseRate: false,
            converted: try Money(135, currency: sgd)
        )
        let snapshot = try NetWorthSnapshot(
            capturedAt: Date(timeIntervalSinceReferenceDate: 200),
            amounts: [try Money(100, currency: usd)],
            estimatedBaseTotal: try Money(135, currency: sgd),
            conversionAsOf: rateDate,
            conversionAsOfDayKey: 20010411,
            conversionEvidence: [evidence]
        )
        var store: EncryptedRecordStore? = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        try await store?.write([
            try RecordWrite(snapshot, id: snapshot.id.uuidString, in: .netWorthSnapshots)
        ])
        await store?.close()
        store = nil

        let reopened = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let restoredSnapshot = try await reopened.fetch(
            NetWorthSnapshot.self,
            id: snapshot.id.uuidString,
            from: .netWorthSnapshots
        )
        XCTAssertEqual(restoredSnapshot, snapshot)
        await reopened.close()
    }

    func testPortableArchiveRoundTripsAndRejectsWrongPassword() throws {
        XCTAssertEqual(PortableArchive.maximumArchiveByteCount, 250_000_000)
        XCTAssertEqual(PortableArchive.maximumNewArchiveByteCount, 64_000_000)
        XCTAssertTrue(
            PortableArchive.isWithinArchiveByteLimit(
                PortableArchive.maximumArchiveByteCount
            )
        )
        XCTAssertFalse(
            PortableArchive.isWithinArchiveByteLimit(
                PortableArchive.maximumArchiveByteCount + 1
            )
        )
        XCTAssertTrue(PortableArchive.isWithinArchiveByteLimit(0))
        XCTAssertFalse(PortableArchive.isWithinArchiveByteLimit(-1))
        XCTAssertTrue(PortableArchive.isWithinNewArchiveByteLimit(
            PortableArchive.maximumNewArchiveByteCount
        ))
        XCTAssertFalse(PortableArchive.isWithinNewArchiveByteLimit(
            PortableArchive.maximumNewArchiveByteCount + 1
        ))

        let snapshot = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                StoredRecordSnapshot(
                    collection: RecordCollection.accounts.rawValue,
                    recordID: "account-1",
                    payload: Data("{\"name\":\"Private\"}".utf8),
                    updatedAt: 123
                )
            ]
        )
        let archive = try PortableArchive.seal(
            snapshot,
            password: "correct horse battery staple"
        )

        XCTAssertEqual(
            try PortableArchive.open(
                archive,
                password: "correct horse battery staple"
            ),
            snapshot
        )
        XCTAssertThrowsError(
            try PortableArchive.open(archive, password: "incorrect password")
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .authenticationFailed)
        }

        let decomposed = "Cafe\u{301}-archive-password"
        let composed = decomposed.precomposedStringWithCanonicalMapping
        let unicodeArchive = try PortableArchive.seal(snapshot, password: decomposed)
        XCTAssertEqual(
            try PortableArchive.open(unicodeArchive, password: composed),
            snapshot
        )

        XCTAssertThrowsError(
            try PortableArchive.seal(snapshot, password: "too short")
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .passwordTooShort)
        }

        XCTAssertThrowsError(
            try PortableArchive.open(archive, password: "short")
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .authenticationFailed)
        }
        XCTAssertThrowsError(
            try PortableArchive.open(
                archive,
                password: String(repeating: "é", count: 513)
            )
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .authenticationFailed)
        }

        let magic = Data("MONEYUP\u{0}".utf8)
        var tamperedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(archive.dropFirst(magic.count))
            ) as? [String: Any]
        )
        var tamperedCiphertext = try XCTUnwrap(
            (tamperedObject["ciphertext"] as? String)
                .flatMap { Data(base64Encoded: $0) }
        )
        let tamperedIndex = tamperedCiphertext.index(
            before: tamperedCiphertext.endIndex
        )
        tamperedCiphertext[tamperedIndex] ^= 0x01
        tamperedObject["ciphertext"] = tamperedCiphertext.base64EncodedString()
        let tampered = magic
            + (try JSONSerialization.data(withJSONObject: tamperedObject))
        XCTAssertThrowsError(
            try PortableArchive.open(
                tampered,
                password: "correct horse battery staple"
            )
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .authenticationFailed)
        }

        var unsupportedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(archive.dropFirst(Data("MONEYUP\u{0}".utf8).count))
            ) as? [String: Any]
        )
        unsupportedObject["version"] = 2
        let unsupported = magic
            + (try JSONSerialization.data(withJSONObject: unsupportedObject))
        XCTAssertThrowsError(
            try PortableArchive.open(
                unsupported,
                password: "correct horse battery staple"
            )
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .unsupportedVersion(2))
        }
    }

    func testPortableArchiveBoundsTheNormalizedPasswordBytes() throws {
        let composedAtLimit = String(repeating: "é", count: 512)
        let decomposedAtLimit = String(repeating: "e\u{301}", count: 512)
        let expected = Data(composedAtLimit.utf8)

        XCTAssertEqual(expected.count, PortableArchive.maximumPasswordByteCount)
        XCTAssertEqual(
            try PortableArchive.validatedPasswordData(composedAtLimit),
            expected
        )
        XCTAssertEqual(
            try PortableArchive.validatedPasswordData(decomposedAtLimit),
            expected
        )

        let tooLong = String(repeating: "é", count: 513)
        XCTAssertThrowsError(
            try PortableArchive.validatedPasswordData(tooLong)
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .passwordTooLong)
        }

        let snapshot = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: []
        )
        XCTAssertThrowsError(
            try PortableArchive.seal(snapshot, password: tooLong)
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .passwordTooLong)
        }
    }

    func testPortableArchiveOpensLegacyLongPasswordVersionOneArchive() throws {
        let snapshot = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: []
        )
        let password = String(repeating: "p", count: 2_048)
        let salt = Data(repeating: 0x5a, count: 16)
        let magic = Data("MONEYUP\u{0}".utf8)
        var authenticatedData = magic
        authenticatedData.append(Data(
            "v=1;kdf=PBKDF2-HMAC-SHA256;i=\(PortableArchive.iterationCount);".utf8
        ))
        authenticatedData.append(salt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(snapshot)
        let key = SymmetricKey(data: try PortableArchive.derivedKeyData(
            password: password,
            salt: salt,
            iterations: PortableArchive.iterationCount
        ))
        let sealed = try AES.GCM.seal(
            payload,
            using: key,
            authenticating: authenticatedData
        )
        let envelope = VersionOnePortableArchiveEnvelope(
            version: 1,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: PortableArchive.iterationCount,
            salt: salt,
            ciphertext: try XCTUnwrap(sealed.combined)
        )
        let archive = magic + (try encoder.encode(envelope))

        XCTAssertEqual(
            try PortableArchive.open(archive, password: password),
            snapshot
        )
    }

    func testPortableArchiveRejectsAttackerSelectedWorkFactorsAndInvalidBox() throws {
        let password = "correct horse battery staple"
        let magic = Data("MONEYUP\u{0}".utf8)
        let originalObject: [String: Any] = [
            "version": 1,
            "kdf": "PBKDF2-HMAC-SHA256",
            "iterations": PortableArchive.iterationCount,
            "salt": Data(repeating: 0x11, count: 16).base64EncodedString(),
            "ciphertext": Data([0x01, 0x02, 0x03]).base64EncodedString()
        ]

        func encodedArchive(_ object: [String: Any]) throws -> Data {
            magic + (try JSONSerialization.data(withJSONObject: object))
        }

        // These include both boundaries that the former permissive range
        // accepted, plus values adjacent to the one canonical v1 cost.
        for workFactor in [10_000, 119_999, 120_001, 1_000_000] {
            var object = originalObject
            object["iterations"] = workFactor
            XCTAssertThrowsError(
                try PortableArchive.open(
                    encodedArchive(object),
                    password: password
                )
            ) { error in
                XCTAssertEqual(error as? PortableArchiveError, .invalidArchive)
            }
        }

        XCTAssertThrowsError(
            try PortableArchive.open(
                encodedArchive(originalObject),
                password: password
            )
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .invalidArchive)
        }
    }

    func testPortableArchiveClassifiesAuthenticatedInvalidPlaintextAsInvalid() throws {
        let password = "correct horse battery staple"
        let magic = Data("MONEYUP\u{0}".utf8)
        let salt = Data(repeating: 0x22, count: 16)
        let key = SymmetricKey(data: try PortableArchive.derivedKeyData(
            password: password,
            salt: salt,
            iterations: PortableArchive.iterationCount
        ))
        var authenticatedData = magic
        authenticatedData.append(Data(
            "v=1;kdf=PBKDF2-HMAC-SHA256;i=\(PortableArchive.iterationCount);".utf8
        ))
        authenticatedData.append(salt)
        let sealed = try AES.GCM.seal(
            Data("authenticated, but not a database snapshot".utf8),
            using: key,
            authenticating: authenticatedData
        )
        let object: [String: Any] = [
            "version": 1,
            "kdf": "PBKDF2-HMAC-SHA256",
            "iterations": PortableArchive.iterationCount,
            "salt": salt.base64EncodedString(),
            "ciphertext": try XCTUnwrap(sealed.combined).base64EncodedString()
        ]
        let malformedPayloadArchive = magic
            + (try JSONSerialization.data(withJSONObject: object))

        XCTAssertThrowsError(
            try PortableArchive.open(
                malformedPayloadArchive,
                password: password
            )
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .invalidArchive)
        }
    }

    private func makeExpenseEntry(
        id: UUID = UUID(),
        occurredAt: Date,
        amount: Decimal,
        firstAccountID: UUID = UUID(),
        secondAccountID: UUID = UUID(),
        originContext: TransactionOriginContext? = nil
    ) throws -> JournalEntry {
        let sgd = try CurrencyCode("SGD")
        return try JournalEntry(
            id: id,
            kind: .expense,
            occurredAt: occurredAt,
            postings: [
                Posting(accountID: firstAccountID, money: try Money(amount, currency: sgd)),
                Posting(accountID: secondAccountID, money: try Money(-amount, currency: sgd))
            ],
            originContext: originContext
        )
    }
}

private actor RestoreStartGate {
    private var reached = false
    private var released = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct TemporaryDatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL
    let key = Data(repeating: 0x11, count: 32)

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        databaseURL = directoryURL.appendingPathComponent("moneyup.sqlite")
    }
}
