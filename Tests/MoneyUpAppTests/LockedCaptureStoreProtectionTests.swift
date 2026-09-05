import CryptoKit
import Foundation
@testable import MoneyUp
import XCTest

final class LockedCaptureStoreProtectionTests: XCTestCase {
    func testDurableInboxUsesAfterFirstUnlockProtectionAcrossRelock() {
        let options = LockedCaptureStore.durableWriteOptions

        XCTAssertTrue(options.contains(.atomic))
        XCTAssertTrue(options.contains(
            .completeFileProtectionUntilFirstUserAuthentication
        ))
        XCTAssertFalse(options.contains(.completeFileProtectionUnlessOpen))
    }

    func testLegacyProtectionUpgradePreservesCiphertextBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUpLockedCaptureProtection-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("locked-captures.bin")
        let queue = [
            LockedCapture(
                id: UUID(),
                kind: .expense,
                amountText: "12.50",
                occurredAt: Date(timeIntervalSinceReferenceDate: 123_456),
                payee: "Cafe",
                note: "Preserve this authenticated queue"
            )
        ]
        let key = SymmetricKey(size: .bits256)
        let plaintext = try JSONEncoder().encode(queue)
        let ciphertext = try XCTUnwrap(
            AES.GCM.seal(plaintext, using: key).combined
        )
        try ciphertext.write(
            to: url,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )

        let fileManager = ProtectionRecordingFileManager()
        try LockedCaptureStore.enforceDurableFileProtection(
            at: url,
            fileManager: fileManager
        )
        XCTAssertEqual(
            fileManager.requestedProtection,
            .completeUntilFirstUserAuthentication
        )

        let reopenedCiphertext = try Data(contentsOf: url)
        XCTAssertEqual(reopenedCiphertext, ciphertext)
        // Simulator filesystems do not expose device Data Protection metadata.
        // The requested policy and authenticated bytes are checked on every host.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
        let reopenedBox = try AES.GCM.SealedBox(combined: reopenedCiphertext)
        let reopenedPlaintext = try AES.GCM.open(reopenedBox, using: key)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [LockedCapture].self,
                from: reopenedPlaintext
            ),
            queue
        )
    }
}

private final class ProtectionRecordingFileManager: FileManager, @unchecked Sendable {
    private(set) var requestedProtection: FileProtectionType?

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        requestedProtection = attributes[.protectionKey] as? FileProtectionType
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
