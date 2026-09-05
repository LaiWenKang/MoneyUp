import Foundation
import MoneyUpCore
@testable import MoneyUpPersistence
import XCTest

final class RawRecordReductionTests: XCTestCase {
    private struct Summary: Equatable, Sendable {
        var keys: [String] = []
        var indices: [Int] = []
        var payloadByteCount = 0
    }

    func testRawRecordReducerCarriesBoundedStateInStableKeyOrder() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let sgd = try CurrencyCode("SGD")
        let first = LedgerAccount(
            id: try XCTUnwrap(
                UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
            ),
            name: "First",
            kind: .asset,
            currency: sgd
        )
        let second = LedgerAccount(
            id: try XCTUnwrap(
                UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")
            ),
            name: "Second",
            kind: .asset,
            currency: sgd
        )
        try await fixture.store.write([
            try RecordWrite(second, id: second.id.uuidString, in: .accounts),
            try RecordWrite(first, id: first.id.uuidString, in: .accounts),
        ])

        let summary = try await fixture.store.reduceStoredRecords(
            into: Summary()
        ) { state, record, index in
            state.indices.append(index)
            state.keys.append("\(record.collection):\(record.recordID)")
            state.payloadByteCount += record.payload.count
        }

        XCTAssertEqual(summary.indices, [0, 1])
        XCTAssertEqual(summary.keys, [
            "accounts:\(first.id.uuidString)",
            "accounts:\(second.id.uuidString)",
        ])
        XCTAssertGreaterThan(summary.payloadByteCount, 0)
        await fixture.store.close()
    }

    func testRawRecordReducerObservesCallerCancellation() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let profile = UserProfile(baseCurrency: try CurrencyCode("SGD"))
        try await fixture.store.write([
            try RecordWrite(
                profile,
                id: UserProfile.primaryRecordID,
                in: .profile
            ),
        ])

        let reduction = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.store.reduceStoredRecords(into: 0) {
                count, _, _ in count += 1
            }
        }
        do {
            _ = try await reduction.value
            XCTFail("Cancelled raw validation must not advance its cursor")
        } catch is CancellationError {
            // The SQL cursor checks before exposing its first payload.
        }
        await fixture.store.close()
    }

    private func makeStore() throws -> (
        directoryURL: URL,
        store: EncryptedRecordStore
    ) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpRawReducer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let store = try EncryptedRecordStore(
            databaseURL: directoryURL.appendingPathComponent("moneyup.sqlite3"),
            key: Data(repeating: 0x4d, count: 32)
        )
        return (directoryURL, store)
    }
}
