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
