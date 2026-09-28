import Foundation
import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

/// From 0.7.3 books use SQLCipher's raw-key form instead of stretching the
/// random 32-byte key as a passphrase on every unlock. New books are raw-keyed;
/// a book from an earlier build moves to the raw key once, by a checked copy
/// that never changes the original in place.
final class DatabaseKeyFormTests: XCTestCase {
    private struct Book: Equatable {
        var accounts: [LedgerAccount]
        var entries: [JournalEntry]

        init(accounts: [LedgerAccount], entries: [JournalEntry]) {
            self.accounts = accounts.sorted { $0.id.uuidString < $1.id.uuidString }
            self.entries = entries.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    private var directoryURL: URL!
    private var databaseURL: URL!
    private let key = Data((0..<32).map { UInt8(($0 * 37 + 11) & 0xff) })

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appendingPathComponent("moneyup.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testRawKeyLiteralIsTheKeyInHex() {
        let literal = SQLCipherConnection.rawKeyLiteral(Data(0..<32))
        XCTAssertEqual(
            String(decoding: literal, as: UTF8.self),
            "x'000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F'"
        )
    }

    func testNewBookIsRawKeyed() async throws {
        let book = try await writeBook()
        XCTAssertEqual(keyForm(), .raw)
        try await assertStore(holds: book)
    }

    func testLegacyBookMovesToTheRawKeyWithEveryRecord() async throws {
        let book = try await writeBook()
        try SQLCipherConnection.rewriteAsLegacyBookForTesting(at: databaseURL, key: key)
        XCTAssertEqual(keyForm(), .passphrase)

        try await assertStore(holds: book)
        XCTAssertEqual(keyForm(), .raw)
        XCTAssertEqual(try leftovers(), [])
        // The next unlock takes the raw path and still finds everything.
        try await assertStore(holds: book)
    }

    func testLegacyBookKeepsWritesStillInItsWriteAheadLog() async throws {
        let book = try await writeBook()
        try SQLCipherConnection.rewriteAsLegacyBookForTesting(at: databaseURL, key: key)
        // An earlier build saves one more account and is killed before its log
        // is folded into the book: copy the files exactly as they are then.
        let legacy = try SQLCipherConnection(
            databaseURL: databaseURL,
            key: key,
            supportedSchemaVersion: EncryptedRecordStore.currentSchemaVersion,
            legacyKeyMove: .skip
        )
        let late = LedgerAccount(name: "Saved just before the crash", kind: .asset)
        try legacy.write([try RecordWrite(late, id: late.id.uuidString, in: .accounts)], removing: [])
        let crashedDirectory = directoryURL.appendingPathComponent("crashed", isDirectory: true)
        try FileManager.default.createDirectory(at: crashedDirectory, withIntermediateDirectories: true)
        let crashedBook = crashedDirectory.appendingPathComponent("moneyup.sqlite")
        try FileManager.default.copyItem(at: databaseURL, to: crashedBook)
        try FileManager.default.copyItem(atPath: databaseURL.path + "-wal", toPath: crashedBook.path + "-wal")
        legacy.close()
        let walSize = try FileManager.default.attributesOfItem(atPath: crashedBook.path + "-wal")[.size] as? Int
        XCTAssertGreaterThan(walSize ?? 0, 0)

        databaseURL = crashedBook
        try await assertStore(holds: Book(accounts: book.accounts + [late], entries: book.entries))
        XCTAssertEqual(keyForm(), .raw)
    }

    func testFailedMoveKeepsTheLegacyBookAndRetriesADayLater() async throws {
        let book = try await writeBook()
        try SQLCipherConnection.rewriteAsLegacyBookForTesting(at: databaseURL, key: key)

        let failing = try SQLCipherConnection(
            databaseURL: databaseURL,
            key: key,
            supportedSchemaVersion: EncryptedRecordStore.currentSchemaVersion,
            legacyKeyMove: .failAfterCopyForTesting
        )
        XCTAssertEqual(try failing.fetchAll(collection: RecordCollection.accounts.rawValue).count, book.accounts.count)
        failing.close()
        XCTAssertEqual(keyForm(), .passphrase)
        let marker = SQLCipherConnection.legacyKeyMoveDeferralURL(for: databaseURL)
        XCTAssertEqual(try leftovers(), [marker.lastPathComponent])

        // Within a day the book opens as it is, without copying it again.
        try await assertStore(holds: book)
        XCTAssertEqual(keyForm(), .passphrase)

        // A day later the move runs, and clears its marker.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)],
            ofItemAtPath: marker.path
        )
        try await assertStore(holds: book)
        XCTAssertEqual(keyForm(), .raw)
        XCTAssertEqual(try leftovers(), [])
    }

    func testDeferredMoveIsDueAgainIfTheClockGoesBackwards() throws {
        let marker = SQLCipherConnection.legacyKeyMoveDeferralURL(for: databaseURL)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        XCTAssertFalse(SQLCipherConnection.legacyKeyMoveIsDue(for: databaseURL))
        XCTAssertTrue(SQLCipherConnection.legacyKeyMoveIsDue(for: databaseURL, now: Date(timeIntervalSinceNow: -3_600)))
        XCTAssertTrue(SQLCipherConnection.legacyKeyMoveIsDue(for: databaseURL, now: Date(timeIntervalSinceNow: 2 * 24 * 60 * 60)))
    }

    func testWrongKeyCannotOpenOrChangeALegacyBook() async throws {
        let book = try await writeBook()
        try SQLCipherConnection.rewriteAsLegacyBookForTesting(at: databaseURL, key: key)
        let before = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(
            try EncryptedRecordStore(databaseURL: databaseURL, key: Data(repeating: 0x22, count: 32))
        ) { error in
            XCTAssertEqual((error as? PersistenceError)?.isNotADatabase, true, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        XCTAssertEqual(try leftovers(), [])
        try await assertStore(holds: book)
    }

    func testCopyLeftByAnInterruptedMoveIsDiscarded() async throws {
        let book = try await writeBook()
        try SQLCipherConnection.rewriteAsLegacyBookForTesting(at: databaseURL, key: key)
        let copyURL = SQLCipherConnection.legacyKeyMoveURL(for: databaseURL)
        try Data(repeating: 0xA5, count: 4_096).write(to: copyURL)
        try Data(repeating: 0x5A, count: 512).write(to: URL(fileURLWithPath: copyURL.path + "-journal"))

        try await assertStore(holds: book)
        XCTAssertEqual(keyForm(), .raw)
        XCTAssertEqual(try leftovers(), [])
    }

    func testMoveWaitsWhileAnotherHandleHasTheBookOpen() async throws {
        let book = try await writeBook()
        try SQLCipherConnection.rewriteAsLegacyBookForTesting(at: databaseURL, key: key)
        let other = try SQLCipherConnection(
            databaseURL: databaseURL,
            key: key,
            supportedSchemaVersion: EncryptedRecordStore.currentSchemaVersion,
            legacyKeyMove: .skip
        )
        XCTAssertEqual(try other.fetchAll(collection: RecordCollection.accounts.rawValue).count, book.accounts.count)

        try await assertStore(holds: book)
        XCTAssertEqual(try other.fetchAll(collection: RecordCollection.accounts.rawValue).count, book.accounts.count)
        other.close()
        XCTAssertEqual(keyForm(), .passphrase)
    }

    // MARK: - Helpers

    private func writeBook() async throws -> Book {
        let store = try EncryptedRecordStore(databaseURL: databaseURL, key: key)
        let sgd = try CurrencyCode("SGD")
        let accounts = ["Wallet", "Card", "Savings"].map { LedgerAccount(name: $0, kind: .asset, currency: sgd) }
        for account in accounts {
            try await store.upsert(account, id: account.id.uuidString, in: .accounts)
        }
        var entries: [JournalEntry] = []
        for (index, amount) in ["12.34", "56.78"].enumerated() {
            let value = Decimal(string: amount)!
            let entry = try JournalEntry(
                kind: .expense,
                payee: "Lunch \(index)",
                postings: [
                    Posting(accountID: accounts[index].id, money: try Money(-value, currency: sgd)),
                    Posting(accountID: UUID(), money: try Money(value, currency: sgd))
                ]
            )
            try await store.upsert(entry, id: entry.id.uuidString, in: .journalEntries)
            entries.append(entry)
        }
        await store.close()
        return Book(accounts: accounts, entries: entries)
    }

    private func assertStore(holds expected: Book, file: StaticString = #filePath, line: UInt = #line) async throws {
        let store = try EncryptedRecordStore(databaseURL: databaseURL, key: key)
        let book = Book(
            accounts: try await store.fetchAll(LedgerAccount.self, from: .accounts),
            entries: try await store.fetchAll(JournalEntry.self, from: .journalEntries)
        )
        await store.close()
        XCTAssertEqual(book, expected, file: file, line: line)
    }

    private func keyForm() -> SQLCipherConnection.KeyForm? {
        SQLCipherConnection.keyFormForTesting(at: databaseURL, key: key)
    }

    /// Files beside the book that a move could leave behind.
    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: databaseURL.deletingLastPathComponent().path)
            .filter { $0.contains("rawkey") || $0.contains("legacy") }
            .sorted()
    }
}
