import Foundation
import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

final class BudgetSchemaCompatibilityTests: XCTestCase {
    func testSchemaNineUpgradesAndOlderReaderRejectsNewBudgetSemantics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.sqlite")
        let key = Data(repeating: 0x2a, count: 32)
        let initial = try EncryptedRecordStore(databaseURL: url, key: key)
        await initial.close()
        let legacy = try SQLCipherConnection(databaseURL: url, key: key, supportedSchemaVersion: 10)
        try legacy.execute("PRAGMA user_version = 9;")
        legacy.close()
        let upgraded = try EncryptedRecordStore(databaseURL: url, key: key)
        let snapshot = try await upgraded.snapshot()
        XCTAssertEqual(snapshot.schemaVersion, 10)
        let node = BudgetNode(name: "Food", limit: try Money(100, currency: CurrencyCode("SGD")), allocationMode: .automatic)
        try await upgraded.upsert(node, id: node.id.uuidString, in: .budgetNodes)
        await upgraded.close()
        XCTAssertThrowsError(try SQLCipherConnection(databaseURL: url, key: key, supportedSchemaVersion: 9)) { error in
            guard case PersistenceError.unsupportedSchema(found: 10, supported: 9) = error else {
                return XCTFail("Older readers must fail before interpreting allocations")
            }
        }
        let reopened = try EncryptedRecordStore(databaseURL: url, key: key)
        let saved = try await reopened.fetch(BudgetNode.self, id: node.id.uuidString, from: .budgetNodes)
        XCTAssertEqual(saved, node)
        await reopened.close()
    }
}
