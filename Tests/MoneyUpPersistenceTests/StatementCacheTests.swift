import Foundation
@testable import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

/// Prepared statements are reused across calls, and a whole-book replacement
/// no longer decodes every entry twice. These pin that neither changes a
/// result, keeps a bound value, or outlives the database handle.
final class StatementCacheTests: XCTestCase {
    private var directoryURL: URL!
    private let key = Data(repeating: 0x5C, count: 32)
    private let password = "correct horse battery staple"

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testRepeatedSQLReusesOnePreparedStatement() throws {
        let connection = try openConnection()
        defer { connection.close() }
        let sql = "SELECT count(*) FROM records;"
        let first = try connection.withStatement(sql) { $0 }
        let second = try connection.withStatement(sql) { $0 }
        XCTAssertEqual(first, second)
        XCTAssertEqual(connection.statementCache[sql], first)
        XCTAssertEqual(try connection.rowsForTesting(sql), [["0"]])
    }

    func testNoBoundValueStaysInACachedStatement() throws {
        let connection = try openConnection()
        defer { connection.close() }
        let marker = "MONEYUP-BOUND-VALUE-MUST-NOT-STAY"
        try connection.upsertRecord(
            collection: RecordCollection.accounts.rawValue,
            recordID: marker,
            payload: Data(marker.utf8),
            updatedAt: 1,
            indexedAt: nil
        )
        XCTAssertEqual(try connection.rowsForTesting("SELECT count(*) FROM records;"), [["1"]])
        let texts = connection.cachedStatementTextsForTesting()
        XCTAssertTrue(texts.contains { $0.contains("INSERT INTO records") })
        XCTAssertFalse(texts.contains { $0.contains(marker) }, "\(texts)")
    }

    func testNestedUseOfRunningSQLGetsItsOwnStatement() throws {
        let connection = try openConnection()
        defer { connection.close() }
        let sql = "SELECT 1;"
        try connection.withStatement(sql) { outer in
            let inner = try connection.withStatement(sql) { $0 }
            XCTAssertNotEqual(inner, outer)
            XCTAssertEqual(connection.statementCache[sql], outer)
        }
        XCTAssertTrue(connection.statementsInUse.isEmpty)
        XCTAssertEqual(try connection.rowsForTesting(sql), [["1"]])
    }

    func testClosingFinalizesStatementsEvenDuringAUse() throws {
        let connection = try openConnection()
        XCTAssertEqual(try connection.rowsForTesting("SELECT count(*) FROM records;"), [["0"]])
        XCTAssertFalse(connection.statementCache.isEmpty)
        try connection.withStatement("SELECT 1;") { _ in connection.close() }
        XCTAssertNil(connection.database)
        XCTAssertTrue(connection.statementCache.isEmpty)
        XCTAssertTrue(connection.statementsInUse.isEmpty)
        XCTAssertThrowsError(try connection.rowsForTesting("SELECT 1;"))
    }

    func testCacheStaysBounded() throws {
        let connection = try openConnection()
        defer { connection.close() }
        for value in 0..<(SQLCipherConnection.statementCacheLimit * 2) {
            XCTAssertEqual(try connection.rowsForTesting("SELECT \(value);"), [["\(value)"]])
        }
        XCTAssertLessThanOrEqual(connection.statementCache.count, SQLCipherConnection.statementCacheLimit)
    }

    func testArchiveRestoreWritesTheSameIntelligenceIndexesAsAFullRebuild() async throws {
        let archiveURL = try await writeArchive(intelligenceEnabled: true)
        let restored = try openConnection(named: "restored.sqlite")
        defer { restored.close() }
        let pageCacheSize = try restored.rowsForTesting("PRAGMA cache_size;")
        _ = try restored.replaceAllRecords(fromPortableArchive: archiveURL, password: password, observesCancellation: false)
        XCTAssertEqual(try restored.rowsForTesting("PRAGMA cache_size;"), pageCacheSize)

        let written = try intelligenceTables(restored)
        XCTAssertEqual(written["journal_intelligence_source_index"]?.count, 42)
        XCTAssertFalse(written["payee_affinity_index"]?.isEmpty ?? true)
        XCTAssertFalse(written["ledger_account_intelligence_index"]?.isEmpty ?? true)
        try restored.rebuildAllIntelligenceIndexesFromRecords()
        XCTAssertEqual(try intelligenceTables(restored), written)
    }

    func testArchiveRestoreLeavesIntelligenceEmptyWhenTheBookTurnedItOff() async throws {
        let archiveURL = try await writeArchive(intelligenceEnabled: false)
        let restored = try openConnection(named: "restored.sqlite")
        defer { restored.close() }
        _ = try restored.replaceAllRecords(fromPortableArchive: archiveURL, password: password, observesCancellation: false)

        let written = try intelligenceTables(restored)
        XCTAssertEqual(written["journal_intelligence_source_index"], [])
        XCTAssertEqual(written["payee_affinity_index"], [])
        XCTAssertEqual(written["ledger_account_intelligence_index"], [])
        XCTAssertEqual(written["intelligence_control"], [["1", "0"]])
        try restored.rebuildAllIntelligenceIndexesFromRecords()
        XCTAssertEqual(try intelligenceTables(restored), written)
    }

    // MARK: - Helpers

    private func openConnection(named name: String = "moneyup.sqlite") throws -> SQLCipherConnection {
        try SQLCipherConnection(
            databaseURL: directoryURL.appendingPathComponent(name),
            key: key,
            supportedSchemaVersion: EncryptedRecordStore.currentSchemaVersion
        )
    }

    /// A book of 42 entries across two payees, exported as an archive.
    private func writeArchive(intelligenceEnabled: Bool) async throws -> URL {
        let store = try EncryptedRecordStore(databaseURL: directoryURL.appendingPathComponent("source.sqlite"), key: key)
        let sgd = try CurrencyCode("SGD")
        let wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)
        let food = LedgerAccount(name: "Food", kind: .expense)
        var writes = [
            try RecordWrite(wallet, id: wallet.id.uuidString, in: .accounts),
            try RecordWrite(food, id: food.id.uuidString, in: .accounts),
            try RecordWrite(
                UserProfile(baseCurrency: sgd, intelligenceEnabled: intelligenceEnabled),
                id: UserProfile.primaryRecordID,
                in: .profile
            )
        ]
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        for index in 0..<42 {
            let date = start.addingTimeInterval(TimeInterval(index * 86_400))
            let entry = try JournalEntry(
                kind: .expense,
                occurredAt: date,
                payee: index.isMultiple(of: 3) ? "South Market" : "North Café",
                postings: [
                    Posting(accountID: food.id, money: try Money(12.34, currency: sgd)),
                    Posting(accountID: wallet.id, money: try Money(-12.34, currency: sgd))
                ],
                originContext: TransactionOriginContext.capture(
                    for: date,
                    timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
                )
            )
            writes.append(try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries))
        }
        try await store.write(writes)
        let archiveURL = directoryURL.appendingPathComponent("book.moneyup")
        try await store.exportPortableArchive(to: archiveURL, password: password)
        await store.close()
        return archiveURL
    }

    private func intelligenceTables(_ connection: SQLCipherConnection) throws -> [String: [[String]]] {
        let tables = [
            "journal_intelligence_source_index",
            "ledger_account_intelligence_index",
            "payee_affinity_index",
            "intelligence_control"
        ]
        return Dictionary(uniqueKeysWithValues: try tables.map { table in
            let rows = try connection.rowsForTesting("SELECT * FROM \(table);")
            return (table, rows.sorted { $0.joined(separator: "\u{1F}") < $1.joined(separator: "\u{1F}") })
        })
    }
}
