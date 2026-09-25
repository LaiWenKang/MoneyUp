import Foundation
@testable import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

/// Persistence regressions from the audit of 0.7.2 (1074.1); see
/// docs/AUDIT_2026-09-25.md. Each test fails on the audited build.
final class Audit1074PersistenceRegressionTests: XCTestCase {
    private struct Probe: Codable, Equatable, Sendable {
        let value: Int
    }

    private func makeStore() throws -> (store: EncryptedRecordStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try EncryptedRecordStore(
            databaseURL: directory.appendingPathComponent("moneyup.sqlite"),
            key: Data(repeating: 0x22, count: 32)
        )
        return (store, directory)
    }

    /// SQLite text binding stops at NUL, so these two identities passed the
    /// duplicate check yet collapsed into one row: the second silently
    /// overwrote the first while the record count still matched.
    func testRestoreRejectsIdentitiesThatDifferOnlyAfterANul() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = UUID().uuidString
        let snapshot = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: ["a", "b"].map { suffix in
                StoredRecordSnapshot(
                    collection: RecordCollection.accounts.rawValue,
                    recordID: base + "\u{0}" + suffix,
                    payload: Data(#"{"value":1}"#.utf8),
                    updatedAt: 1
                )
            }
        )
        do {
            try await store.restore(snapshot)
            XCTFail("A NUL-bearing identity must not restore")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .invalidSnapshot)
        }
        await store.close()
    }

    func testWritesRefuseANulInsteadOfTruncatingTheIdentity() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = UUID().uuidString
        try await store.upsert(Probe(value: 1), id: base, in: .pendingLockedCaptures)
        do {
            try await store.upsert(Probe(value: 2), id: base + "\u{0}shadow", in: .pendingLockedCaptures)
            XCTFail("A NUL-bearing identity must not be written")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .invalidQuery)
        }
        // The existing record was not overwritten through the truncated identity,
        // and the connection stays usable after the refused write.
        let stored = try await store.fetchAll(Probe.self, from: .pendingLockedCaptures)
        XCTAssertEqual(stored, [Probe(value: 1)])
        try await store.upsert(Probe(value: 3), id: base, in: .pendingLockedCaptures)
        let updated = try await store.fetchAll(Probe.self, from: .pendingLockedCaptures)
        XCTAssertEqual(updated, [Probe(value: 3)])
        await store.close()
    }
}
