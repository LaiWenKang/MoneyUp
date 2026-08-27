import Foundation
@testable import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

final class EncryptedRecordStoreTests: XCTestCase {
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
