import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

/// S1: a book with damaged rows backs up byte for byte. Restoring it keeps
/// those rows set aside exactly as a normal open of the source book does, and
/// only after the person confirms a preview that counts them. Anything else
/// stays all or nothing.
final class RecoveringRestoreTests: XCTestCase {
    private let password = "recovering-restore"
    private static let unreadable = Data(#"{"unreadable":true}"#.utf8)

    /// Two kinds of damage a normal open sets aside: an expense whose
    /// category is missing from the book, and an account row that no longer
    /// decodes.
    @MainActor
    private func seedDamagedBook(
        _ fixture: AppModelFixture
    ) async throws -> (entry: JournalEntry, damagedAccount: StoredRecordSnapshot) {
        let entry = try fixture.expense(amount: 7)
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet],
            entries: [entry]
        )
        let damagedAccount = StoredRecordSnapshot(
            collection: RecordCollection.accounts.rawValue,
            recordID: UUID().uuidString,
            payload: Self.unreadable,
            updatedAt: 1
        )
        let snapshot = try await fixture.store.snapshot()
        try await fixture.store.restore(DatabaseSnapshot(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            records: snapshot.records + [damagedAccount]
        ))
        return (entry, damagedAccount)
    }

    @MainActor
    func testConfirmedRestoreKeepsDamagedRowsSetAsideAndRestoresEveryValidRecord()
        async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let (entry, damagedAccount) = try await seedDamagedBook(fixture)
        let model = fixture.model(accounts: [fixture.wallet])
        // What a normal open of the source book sets aside.
        try await model.load(from: fixture.store)
        let setAsideBySource = model.recoveryIssues
        XCTAssertTrue(setAsideBySource.contains("accounts/\(damagedAccount.recordID)"))
        XCTAssertTrue(setAsideBySource.contains("journal_entries/\(entry.id.uuidString)"))
        let archiveURL = fixture.directoryURL.appendingPathComponent("damaged.moneyup")
        try await model.encryptedBackup(to: archiveURL, password: password)

        // Without a reviewed ticket a restore stays all or nothing.
        do {
            try await model.restoreEncryptedBackup(from: archiveURL, password: password)
            XCTFail("An unreviewed restore must refuse damaged rows")
        } catch AppModelError.invalidBook {}

        // The live book changes after the backup; the restore must replace it.
        try await fixture.store.upsert(
            fixture.usAccount,
            id: fixture.usAccount.id.uuidString,
            in: .accounts
        )
        let ticket = try await model.prepareEncryptedRestorePreview(
            from: archiveURL,
            password: password
        )
        let candidate = ticket.preview.candidate
        XCTAssertEqual(candidate.quarantinedRecordCount, setAsideBySource.count)
        XCTAssertEqual(ticket.damagePolicy, .confirmed(setAsideBySource.count))
        XCTAssertEqual(candidate.storedRecordCount(in: .accounts), 2)
        XCTAssertEqual(candidate.storedRecordCount(in: .journalEntries), 1)
        // The preview summarizes only the entries a normal open shows.
        XCTAssertNil(candidate.entryDateSpan)

        try await model.restoreEncryptedBackup(ticket, password: password)

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.accounts.map(\.id), [fixture.wallet.id])
        XCTAssertEqual(Set(model.recoveryIssues), Set(setAsideBySource))
        XCTAssertEqual(model.recoveryIssueCount, candidate.quarantinedRecordCount)
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(entry.id))
        let restored = try await fixture.store.snapshot().records
        XCTAssertTrue(restored.contains(damagedAccount), "Damaged rows return byte for byte")
        XCTAssertTrue(restored.contains { $0.recordID == entry.id.uuidString })
        XCTAssertFalse(restored.contains { $0.recordID == fixture.usAccount.id.uuidString })

        // The restored book backs up and restores the same way again.
        let againURL = fixture.directoryURL.appendingPathComponent("again.moneyup")
        try await model.encryptedBackup(to: againURL, password: password)
        let again = try await model.prepareEncryptedRestorePreview(
            from: againURL,
            password: password
        )
        XCTAssertEqual(again.preview.candidate.quarantinedRecordCount, setAsideBySource.count)
    }

    @MainActor
    func testACommitKeepsOnlyTheDamagedRowsItsPreviewShowed() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        _ = try await seedDamagedBook(fixture)
        let model = fixture.model(accounts: [fixture.wallet])
        let archiveURL = fixture.directoryURL.appendingPathComponent("damaged.moneyup")
        try await model.encryptedBackup(to: archiveURL, password: password)
        let ticket = try await model.prepareEncryptedRestorePreview(
            from: archiveURL,
            password: password
        )
        let shown = ticket.preview.candidate.quarantinedRecordCount
        XCTAssertGreaterThanOrEqual(shown, 2)
        let liveBefore = try await fixture.store.snapshot().records

        for claimed in [0, shown - 1, shown + 1] {
            do {
                try await model.restoreEncryptedBackup(
                    ticket.confirming(claimed),
                    password: password
                )
                XCTFail("A preview of \(shown) damaged rows must not commit \(claimed)")
            } catch AppModelError.invalidBook where claimed == 0 {
            } catch AppModelError.restorePreviewChanged where claimed > 0 {}
            let liveAfter = try await fixture.store.snapshot().records
            XCTAssertEqual(liveAfter, liveBefore, "A refused commit leaves the live book as it was")
            XCTAssertEqual(model.state, .ready)
        }

        try await model.restoreEncryptedBackup(ticket, password: password)
        XCTAssertEqual(model.recoveryIssueCount, shown)
    }

    @MainActor
    func testOnlyRowsANormalOpenSetsAsideCanBeSetAsideByARestore() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food]
        )
        let valid = try await fixture.store.snapshot()
        let model = fixture.model(accounts: [fixture.wallet, fixture.food])
        func preview(adding extra: StoredRecordSnapshot) async throws -> RestorePreviewTicket {
            let url = fixture.directoryURL.appendingPathComponent(
                "\(UUID().uuidString).moneyup"
            )
            try PortableArchive.seal(
                DatabaseSnapshot(
                    schemaVersion: valid.schemaVersion,
                    records: valid.records + [extra]
                ),
                password: password,
                to: url
            )
            return try await model.prepareEncryptedRestorePreview(from: url, password: password)
        }
        func row(
            _ collection: RecordCollection,
            _ recordID: String,
            _ payload: Data
        ) -> StoredRecordSnapshot {
            StoredRecordSnapshot(
                collection: collection.rawValue,
                recordID: recordID,
                payload: payload,
                updatedAt: 1
            )
        }

        let setAside = try await preview(
            adding: row(.accounts, UUID().uuidString, Self.unreadable)
        )
        XCTAssertEqual(setAside.preview.candidate.quarantinedRecordCount, 1)
        XCTAssertEqual(setAside.damagePolicy, .confirmed(1))

        let oversizedGoal = try JSONSerialization.data(withJSONObject: [
            "movements": Array(
                repeating: [String: Any](),
                count: SavingsGoal.maximumMovementCount + 1
            ),
        ])
        let refused = [
            row(.journalEntryRevisions, UUID().uuidString, Self.unreadable),
            row(.accountLifecycleAudit, UUID().uuidString, Self.unreadable),
            row(.cloudBackupIdentity, CloudBackupBookIdentity.recordID, Self.unreadable),
            row(
                .budgetConfigurationTimelines,
                BudgetPeriodRecoveryOriginal.recordID,
                Self.unreadable
            ),
            // Work limits never relax, even for a row the open would set aside.
            row(.savingsGoals, UUID().uuidString, oversizedGoal),
        ]
        for record in refused {
            do {
                _ = try await preview(adding: record)
                XCTFail("\(record.collection) damage must still refuse the backup")
            } catch AppModelError.invalidBook {}
        }
    }

    @MainActor
    func testAMalformedDraftIsCountedAndKeptByteForByte() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food]
        )
        let draftRow = StoredRecordSnapshot(
            collection: RecordCollection.quickLogDrafts.rawValue,
            recordID: QuickLogDraft.primaryRecordID,
            payload: Data(#"{"kind":42}"#.utf8),
            updatedAt: 1
        )
        let snapshot = try await fixture.store.snapshot()
        let archiveURL = fixture.directoryURL.appendingPathComponent("draft.moneyup")
        try PortableArchive.seal(
            DatabaseSnapshot(
                schemaVersion: snapshot.schemaVersion,
                records: snapshot.records + [draftRow]
            ),
            password: password,
            to: archiveURL
        )
        let model = fixture.model(accounts: [fixture.wallet, fixture.food])

        let ticket = try await model.prepareEncryptedRestorePreview(
            from: archiveURL,
            password: password
        )
        XCTAssertEqual(ticket.preview.candidate.quarantinedRecordCount, 1)
        try await model.restoreEncryptedBackup(ticket, password: password)

        XCTAssertNil(model.quickLogDraft)
        XCTAssertEqual(model.recoveryIssueCount, 1)
        XCTAssertTrue(model.recoveryIssues.contains(
            "quick_log_drafts/\(QuickLogDraft.primaryRecordID)"
        ))
        let restored = try await fixture.store.snapshot().records
        XCTAssertTrue(restored.contains(draftRow), "Restore never repairs or drops the draft")
    }

    @MainActor
    func testKeyCliffRecoveryRestoresADamagedBackupWithItsRowsSetAside() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let (entry, damagedAccount) = try await seedDamagedBook(fixture)
        let recoveryKey = Data(repeating: 0x5d, count: 32)
        let model = fixture.model(
            accounts: [fixture.wallet],
            keyCliffRecoveryKeyAccess: KeyCliffRecoveryKeyAccess(
                generate: { recoveryKey },
                store: { _ in },
                delete: {}
            )
        )
        let archiveURL = fixture.directoryURL.appendingPathComponent("key-cliff.moneyup")
        try await model.encryptedBackup(to: archiveURL, password: password)
        await fixture.store.close()
        model.store = nil
        model.storeGeneration &+= 1
        model.clearDecodedState()
        model.startupFailureKind = .missingDeviceBoundKey
        model.state = .failed(AppLocalization.string("error.missing_device_bound_key"))

        let ticket = try await model.prepareEncryptedRestorePreview(
            from: archiveURL,
            password: password
        )
        let shown = ticket.preview.candidate.quarantinedRecordCount
        XCTAssertEqual(ticket.preview.current, .inaccessible)
        XCTAssertGreaterThanOrEqual(shown, 2)
        XCTAssertEqual(ticket.damagePolicy, .confirmed(shown))

        try await model.restoreEncryptedBackup(ticket, password: password)

        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.startupFailureKind)
        XCTAssertEqual(model.recoveryIssueCount, shown)
        XCTAssertEqual(model.accounts.map(\.id), [fixture.wallet.id])
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(entry.id))
        let liveStore = try XCTUnwrap(model.store)
        let restored = try await liveStore.snapshot().records
        XCTAssertTrue(restored.contains(damagedAccount), "Damaged rows return byte for byte")
        XCTAssertFalse(KeyCliffRecoveryTransaction.hasPendingManifest(for: fixture.databaseURL))
        await liveStore.close()
    }

    func testKeyCliffManifestCarriesTheConfirmedCountThroughRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KeyCliffManifest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("moneyup.sqlite")
        try Data("original".utf8).write(to: databaseURL)
        let manifestURL = KeyCliffRecoveryTransaction.directoryURL(for: databaseURL)
            .appendingPathComponent("pending.json")
        func publish(_ count: Int) throws {
            try KeyCliffRecoveryTransaction.prepareCandidateDirectory(for: databaseURL)
            try Data("candidate".utf8).write(
                to: KeyCliffRecoveryTransaction.candidateDatabaseURL(for: databaseURL)
            )
            try KeyCliffRecoveryTransaction.publishManifest(
                for: databaseURL,
                setAsideRecordCount: count
            )
        }

        try publish(0)
        XCTAssertEqual(try KeyCliffRecoveryTransaction.damagePolicy(for: databaseURL), .reject)
        let allOrNothing = String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
        XCTAssertFalse(
            allOrNothing.contains("setAsideRecordCount"),
            "An all-or-nothing manifest keeps the earlier format"
        )
        try KeyCliffRecoveryTransaction.removeAll(for: databaseURL)

        try publish(3)
        XCTAssertEqual(
            try KeyCliffRecoveryTransaction.damagePolicy(for: databaseURL),
            .confirmed(3)
        )
        try KeyCliffRecoveryTransaction.beginRollback(for: databaseURL)
        XCTAssertEqual(try KeyCliffRecoveryTransaction.phase(for: databaseURL), .rollingBack)
        XCTAssertEqual(
            try KeyCliffRecoveryTransaction.damagePolicy(for: databaseURL),
            .confirmed(3)
        )
        try KeyCliffRecoveryTransaction.removeAll(for: databaseURL)

        // A manifest written before the count existed resumes all or nothing.
        // A count of zero or less is never written, so it fails closed.
        let prefix = #"{"version":1,"originalArtifactMask":1,"candidateArtifactMask":1,"phase":"installing""#
        let cases: [(String, RestoreDamagePolicy?)] = [
            (prefix + "}", .reject),
            (prefix + #","setAsideRecordCount":0}"#, nil),
            (prefix + #","setAsideRecordCount":-2}"#, nil),
        ]
        for (json, expected) in cases {
            try KeyCliffRecoveryTransaction.prepareCandidateDirectory(for: databaseURL)
            try Data(json.utf8).write(to: manifestURL)
            if let expected {
                XCTAssertEqual(
                    try KeyCliffRecoveryTransaction.damagePolicy(for: databaseURL),
                    expected
                )
            } else {
                do {
                    _ = try KeyCliffRecoveryTransaction.damagePolicy(for: databaseURL)
                    XCTFail("A manifest claiming \(json) must fail closed")
                } catch AppModelError.restoreRecoveryFailed {}
            }
            try KeyCliffRecoveryTransaction.removeAll(for: databaseURL)
        }
    }
}

private extension RestorePreviewTicket {
    /// The same staged bytes with a different confirmed count, as a stale or
    /// forged confirmation would carry.
    func confirming(_ count: Int) -> RestorePreviewTicket {
        let candidate = preview.candidate
        return RestorePreviewTicket(
            preview: RestorePreview(
                archiveFormatVersion: preview.archiveFormatVersion,
                archiveSchemaVersion: preview.archiveSchemaVersion,
                current: preview.current,
                candidate: RestorePreview.BookSummary(
                    storedRecordCounts: candidate.storedRecordCounts,
                    entryDateSpan: candidate.entryDateSpan,
                    currencies: candidate.currencies,
                    quarantinedRecordCount: count,
                    reportingTimeZoneIdentifier: candidate.reportingTimeZoneIdentifier
                )
            ),
            stagedArchiveURL: stagedArchiveURL,
            archiveFingerprint: archiveFingerprint
        )
    }
}
