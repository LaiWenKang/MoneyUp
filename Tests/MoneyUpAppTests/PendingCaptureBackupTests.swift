import Foundation
import MoneyUpCore
import MoneyUpPersistence
import XCTest
@testable import MoneyUp

final class PendingCaptureBackupTests: XCTestCase {
    private let password = "Synthetic backup password"

    @MainActor
    func testRepeatedBackupsKeepExistingDraftAndEveryCaptureWithoutDuplicates() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let captures = [
            LockedCapture(kind: .expense, amountText: "12.30", payee: "First", note: "Keep this"),
            LockedCapture(kind: .transfer, amountText: "45", occurredAt: Date(timeIntervalSince1970: 1)),
            LockedCapture(kind: .refund, amountText: "2.50"),
            LockedCapture(kind: .income, amountText: "900")
        ]
        let draft = QuickLogDraft(kind: .income, amountText: "18.20", destinationAmountText: "",
            accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: nil,
            occurredAt: Date(), dateWasEdited: true, payee: "Existing", note: "Unfinished", smartText: "")
        let inbox = InMemoryLockedCaptureStore(captures: captures)
        let model = fixture.model(quickLogDraft: draft, lockedCaptureStore: inbox)
        for _ in 0..<2 {
            let archive = try await model.encryptedBackup(password: password)
            let snapshot = try PortableArchive.open(archive, password: password)
            try RestoreCandidateValidator.validateSnapshotIdentities(snapshot)
            let archived = try snapshot.records.filter {
                $0.collection == RecordCollection.pendingLockedCaptures.rawValue
            }.map { try JSONDecoder().decode(ArchivedLockedCapture.self, from: $0.payload) }
                .sorted { $0.position < $1.position }
            XCTAssertEqual(archived.map(\.capture), captures)
            let draftRecord = try XCTUnwrap(snapshot.records.first {
                $0.collection == RecordCollection.quickLogDrafts.rawValue
            })
            XCTAssertEqual(try JSONDecoder().decode(QuickLogDraft.self, from: draftRecord.payload), draft)
            XCTAssertEqual(model.quickLogDraft, draft)
            XCTAssertEqual(model.pendingLockedCaptureCount, captures.count)
            let remaining = try await inbox.all()
            XCTAssertEqual(remaining, captures)
            XCTAssertNil(model.requestedQuickLogRequest)
        }
        await fixture.store.close()
    }

    @MainActor
    func testReviewedRestoreKeepsCaptureOrderAndSavingPromotesEachExactlyOnce() async throws {
        let source = try AppModelFixture()
        let destination = try AppModelFixture()
        defer { source.removeFiles(); destination.removeFiles() }
        let profile = UserProfile(baseCurrency: source.sgd)
        try await source.seed(profile: profile, accounts: [source.wallet, source.food])
        let first = LockedCapture(kind: .expense, amountText: "10", payee: "First")
        let second = LockedCapture(kind: .expense, amountText: "20",
            occurredAt: Date(timeIntervalSince1970: 1), payee: "Second")
        let sourceModel = source.model(profile: profile, lockedCaptureStore:
            InMemoryLockedCaptureStore(captures: [first, second]))
        let archiveURL = source.directoryURL.appendingPathComponent("pending.moneyup")
        try await sourceModel.encryptedBackup(to: archiveURL, password: password)
        let targetInbox = InMemoryLockedCaptureStore(captures: [])
        let model = destination.model(lockedCaptureStore: targetInbox)
        let ticket = try await model.prepareEncryptedRestorePreview(from: archiveURL, password: password)
        try await model.restoreEncryptedBackup(ticket, password: password)
        XCTAssertEqual(model.pendingLockedCaptureCount, 2)
        XCTAssertNil(model.quickLogDraft)
        let targetDeviceCaptures = try await targetInbox.all()
        XCTAssertTrue(targetDeviceCaptures.isEmpty, "Restore keeps protected captures inside the encrypted book")

        try await model.reviewPendingLockedCapturesForBackup()
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, first.id)
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)
        _ = try await model.logExpense(amount: 10, accountID: source.wallet.id,
            categoryID: source.food.id, occurredAt: first.occurredAt, payee: first.payee, note: nil)
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, second.id)
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        _ = try await model.logExpense(amount: 20, accountID: source.wallet.id,
            categoryID: source.food.id, occurredAt: second.occurredAt, payee: second.payee, note: nil)
        try await model.promotePendingLockedCapture()
        XCTAssertNil(model.quickLogDraft)
        XCTAssertEqual(model.entries.count, 2)
        let count = try await destination.store.count(in: .pendingLockedCaptures)
        XCTAssertEqual(count, 0)
        await source.store.close()
        await destination.store.close()
    }

    @MainActor
    func testFailedExportAndInterruptedPromotionPreserveEveryCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(kind: .expense, amountText: "10", payee: "Keep me")
        let inbox = InMemoryLockedCaptureStore(captures: [capture], removeFailuresRemaining: 1)
        let model = fixture.model(lockedCaptureStore: inbox)
        let blockedParent = fixture.directoryURL.appendingPathComponent("blocked")
        try Data("synthetic file".utf8).write(to: blockedParent)
        let impossibleDestination = blockedParent.appendingPathComponent("backup.moneyup")
        do {
            try await model.encryptedBackup(to: impossibleDestination, password: password)
            XCTFail("A file used as the output directory must fail export")
        } catch {}
        XCTAssertFalse(model.isWorking)
        let retained = try await model.pendingLockedCaptures(in: fixture.store)
        XCTAssertEqual(retained, [capture])
        do {
            try await model.promotePendingLockedCapture()
            XCTFail("Injected inbox deletion failure must be reported")
        } catch LockedCaptureStoreError.unavailable {}
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, capture.id)
        _ = try await model.encryptedBackup(password: password)
        try await model.promotePendingLockedCapture()
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, capture.id)
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        let remaining = try await model.pendingLockedCaptures(in: fixture.store)
        XCTAssertTrue(remaining.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testConflictingCopiesCannotOverwriteOriginalCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(kind: .expense, amountText: "10")
        let conflicting = LockedCapture(id: capture.id, kind: .expense, amountText: "999")
        try await fixture.store.upsert(ArchivedLockedCapture(capture: capture, position: 0),
            id: capture.id.uuidString, in: .pendingLockedCaptures)
        let inbox = InMemoryLockedCaptureStore(captures: [conflicting])
        let model = fixture.model(lockedCaptureStore: inbox)
        do {
            _ = try await model.encryptedBackup(password: password)
            XCTFail("Conflicting source copies must not be silently replaced")
        } catch AppModelError.invalidBook {}
        let bookCopies = try await model.archivedLockedCaptures(in: fixture.store)
        XCTAssertEqual(bookCopies.map(\.capture), [capture])
        let deviceCopies = try await inbox.all()
        XCTAssertEqual(deviceCopies, [conflicting])
        await fixture.store.close()
    }

    func testRestoreRejectsAmbiguousOrderInvalidPayloadAndWrongIdentity() throws {
        let first = LockedCapture(kind: .expense, amountText: "10")
        let second = LockedCapture(kind: .income, amountText: "20")
        func record(_ capture: LockedCapture, position: Int, recordID: String? = nil) throws -> StoredRecordSnapshot {
            StoredRecordSnapshot(collection: RecordCollection.pendingLockedCaptures.rawValue,
                recordID: recordID ?? capture.id.uuidString,
                payload: try JSONEncoder().encode(ArchivedLockedCapture(capture: capture, position: position)),
                updatedAt: 1)
        }
        for records in [
            try [record(first, position: 0), record(second, position: 0)],
            try [record(first, position: -1)],
            try [record(first, position: 0, recordID: UUID().uuidString)],
            try [record(LockedCapture(kind: .expense, amountText: ""), position: 0)]
        ] {
            let snapshot = DatabaseSnapshot(schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: records)
            XCTAssertThrowsError(try RestoreCandidateValidator.validateSnapshotIdentities(snapshot))
        }
    }
}
