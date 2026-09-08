import Foundation
@testable import MoneyUpPersistence
import XCTest

final class PortableArchiveVerificationTests: XCTestCase {
    func testStreamingVerificationAuthenticatesEveryChunkAndRejectsWrongPasswordOrTampering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verify-\(UUID()).moneyup")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = DatabaseSnapshot(schemaVersion: EncryptedRecordStore.currentSchemaVersion, records: [
            StoredRecordSnapshot(collection: "receipt_attachments", recordID: UUID().uuidString,
                payload: Data(repeating: 0x41, count: 2_500_000), updatedAt: 123)
        ])
        let password = "Synthetic verification password"
        try PortableArchive.seal(snapshot, password: password, to: url)
        let original = try Data(contentsOf: url)
        try PortableArchive.verify(from: url, password: password)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try PortableArchive.verify(from: url, password: "wrong password"))
        var damaged = original
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: url)
        XCTAssertThrowsError(try PortableArchive.verify(from: url, password: password))
    }

    func testVerificationHonorsCancellationWithoutChangingTheArchive() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verify-cancel-\(UUID()).moneyup")
        defer { try? FileManager.default.removeItem(at: url) }
        try PortableArchive.seal(DatabaseSnapshot(schemaVersion: EncryptedRecordStore.currentSchemaVersion, records: []),
            password: "Synthetic verification password", to: url)
        let original = try Data(contentsOf: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try PortableArchive.verify(from: url, password: "Synthetic verification password")
        }
        do { try await task.value; XCTFail("Cancelled verification must not report success") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
