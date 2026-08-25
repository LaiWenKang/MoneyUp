import Foundation
@testable import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

final class EncryptedRecordStoreTests: XCTestCase {
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
        XCTAssertEqual(try await store.count(in: .accounts), 2)

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
