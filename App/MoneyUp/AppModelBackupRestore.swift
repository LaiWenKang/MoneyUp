import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    private struct RestorePreparation {
        let store: EncryptedRecordStore
        let generation: Int
        let stateBeforeRestore: State
    }

    private struct RestoreRollbackArchive {
        let url: URL
        let password: String
    }

    func encryptedBackup(password: String) async throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Backup-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await encryptedBackup(to: temporaryURL, password: password)
        return try Data(contentsOf: temporaryURL)
    }

    /// Production backup entry point. The returned artifact stays file-backed
    /// from the SQL cursor through SwiftUI's export handoff.
    func encryptedBackup(
        to destinationURL: URL,
        password: String
    ) async throws {
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        isWorking = true
        defer {
            isWorking = false
            endLifecycleMutation()
        }

        // A portable archive contains the SQLCipher snapshot but not the
        // separately encrypted, book-agnostic locked-capture inbox. Refuse to
        // label an incomplete recovery point as ready.
        let backupStore = try requireStore()
        try await flushQuickLogDraftForBackup(to: backupStore)
        try await requireEmptyLockedCaptureInbox()
        try Task.checkCancellation()
        let metrics = try await backupStore.storageMetrics()
        guard metrics.recordCount
                <= RestoreCandidateValidator.maximumCandidateRecordCount,
              metrics.payloadByteCount
                <= RestoreCandidateValidator.maximumBackupStoredPayloadByteCount,
              metrics.recordIDByteCount
                <= RestoreCandidateValidator.maximumAggregateRecordIDByteCount,
              metrics.collectionByteCount
                <= RestoreCandidateValidator.maximumAggregateCollectionByteCount else {
            throw PortableArchiveError.archiveTooLarge
        }
        try Task.checkCancellation()
        try await backupStore.exportPortableArchive(
            to: destinationURL,
            password: password
        )
    }

    #if DEBUG
    /// Test-only compatibility entry points. Release UI and release binaries
    /// can restore only with a `RestorePreviewTicket` whose private commit copy
    /// is reverified before this transaction primitive is reached.
    func restoreEncryptedBackup(_ data: Data, password: String) async throws {
        guard PortableArchive.isWithinArchiveByteLimit(data.count) else {
            throw PortableArchiveError.archiveTooLarge
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Imported-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])
        try await restoreEncryptedBackup(
            from: temporaryURL,
            password: password
        )
    }

    func restoreEncryptedBackup(
        from archiveURL: URL,
        password: String
    ) async throws {
        if startupFailureKind == .missingDeviceBoundKey {
            throw AppModelError.restorePreviewRequired
        }
        try await restoreEncryptedBackupIntoLiveStore(
            from: archiveURL,
            password: password
        )
    }

    private func restoreEncryptedBackupIntoLiveStore(
        from archiveURL: URL,
        password: String
    ) async throws {
        try await beginRestoreMutation()
        defer { finishBookReplacementMutation() }

        try await restoreEncryptedBackupAfterVerifiedTicket(
            from: archiveURL,
            password: password
        )
    }
    #endif

    func restoreEncryptedBackupAfterVerifiedTicket(
        from archiveURL: URL,
        password: String
    ) async throws {
        let preparation = try await prepareRestore(
            from: archiveURL,
            password: password
        )
        let restoreStore = preparation.store
        let generation = preparation.generation

        let rollback = try await makeRestoreRollbackArchive(
            from: restoreStore,
            generation: generation
        )
        defer {
            try? Self.removeRestoreTemporaryArchive(
                restoreRollbackDirectoryURL
            )
        }

        await lifecycleHooks.checkpoint(.beforeRestoreCommit)
        try Task.checkCancellation()
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }

        let retainedEntriesBeforeRestore = retainsCompleteJournal ? entries : nil
        var liveStoreWasReplaced = false
        // The actor can finish its replacement transaction while this main-
        // actor task is suspended. Make every old-book derived value and
        // destructive reference decision fail closed before that handoff.
        invalidateCommittedJournalProjection(invalidateRecentEntries: true)
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        do {
            try await restoreStore.restorePortableArchive(
                from: archiveURL,
                password: password
            )
            liveStoreWasReplaced = true
            await lifecycleHooks.checkpoint(
                .afterRestoreCommitBeforeCandidateLoad
            )
            try await validateAndPublishRestoredBook(
                from: restoreStore,
                generation: generation
            )
        } catch {
            if case PersistenceError.restoreTransactionStateIndeterminate = error {
                // A failed SQLite rollback means neither the old nor candidate
                // state may be trusted. Force the same authoritative recovery
                // used after a committed candidate before republishing data.
                liveStoreWasReplaced = true
            }
            guard liveStoreWasReplaced else {
                // A failed/rolled-back store replacement leaves the old durable
                // book intact. Restore the deliberately cleared complete test/
                // preview journal so the normal idle-end republish cannot mark
                // a false empty cache as current.
                if let retainedEntriesBeforeRestore {
                    entries = retainedEntriesBeforeRestore
                }
                throw error
            }
            do {
                try await recoverRestoreRollback(
                    store: restoreStore,
                    archiveURL: rollback.url,
                    password: rollback.password,
                    generation: generation,
                    stateBeforeRestore: preparation.stateBeforeRestore
                )
            } catch {
                clearDecodedState()
                state = .failed(
                    AppModelError.restoreRecoveryFailed.localizedDescription
                )
                throw AppModelError.restoreRecoveryFailed
            }
            throw error
        }
    }

    func beginRestoreMutation() async throws {
        guard !isWorking,
              !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !isJournalMutationInProgress else {
            throw AppModelError.transactionInProgress
        }
        // Close admission before the first suspension. A normal restore keeps
        // the same store actor, so a distinct logical revision invalidates
        // every old-book read even if it resumes after replacement finishes.
        isBookReplacementInProgress = true
        logicalBookRevision &+= 1
        isWorking = true
        goalMutationBarrierClosed = true
        await waitForGoalMutationDrain()
        isLifecycleMutationInProgress = true
        requestedQuickLogMode = nil
        intelligenceService.cancelPendingWork()
        invalidateInFlightJournalProjection()
    }

    private func makeRestoreRollbackArchive(
        from store: EncryptedRecordStore,
        generation: Int
    ) async throws -> RestoreRollbackArchive {
        try Self.removeRestoreTemporaryArchive(restoreRollbackDirectoryURL)
        try FileManager.default.createDirectory(
            at: restoreRollbackDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = restoreRollbackArchiveURL
        let password = UUID().uuidString + UUID().uuidString
        do {
            try await store.exportPortableArchive(to: url, password: password)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: url.path
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            return RestoreRollbackArchive(url: url, password: password)
        } catch {
            try? Self.removeRestoreTemporaryArchive(
                restoreRollbackDirectoryURL
            )
            throw error
        }
    }

    private func prepareRestore(
        from archiveURL: URL,
        password: String
    ) async throws -> RestorePreparation {
        let restoreStore = try requireStore()
        // The redacted inbox cannot safely cross book replacement.
        try await requireEmptyLockedCaptureInbox()
        do {
            try Self.removeRestoreValidationDirectory(
                restoreValidationDirectoryURL
            )
            try Self.removeLegacyRestoreValidationDirectories()
        } catch {
            throw AppModelError.invalidBook
        }
        try Task.checkCancellation()

        let preparation = RestorePreparation(
            store: restoreStore,
            generation: storeGeneration,
            stateBeforeRestore: state
        )
        try await validateRestoreCandidateInIsolation(
            from: archiveURL,
            password: password
        )
        try Task.checkCancellation()

        // Authentication and full isolated validation must finish before this
        // restore attempt writes any live-store byte. Once accepted, drain a
        // debounce that may already be inside its store operation, then persist
        // the newest in-memory draft before creating the rollback checkpoint.
        await finishPendingQuickLogDraftWrite()
        try Task.checkCancellation()
        try await flushQuickLogDraftForBackup(to: restoreStore)
        return preparation
    }

    private func validateAndPublishRestoredBook(
        from store: EncryptedRecordStore,
        generation: Int
    ) async throws {
        try Task.checkCancellation()
        guard ownsStoreGeneration(generation) else {
            throw AppModelError.locked
        }
        try await load(from: store, mode: .restoreValidation)
        try Task.checkCancellation()
        guard ownsStoreGeneration(generation) else {
            throw AppModelError.locked
        }
        guard profile != nil else { throw AppModelError.invalidBook }
        try validateLoadedBook()
        try await RestoreCandidateValidator.validateRelationships(
            profile: profile,
            accounts: accounts,
            budgetNodes: budgetNodes,
            scheduledTransactions: scheduledTransactions,
            investmentHoldings: investmentHoldings,
            netWorthSnapshots: netWorthSnapshots,
            quickLogDraft: quickLogDraft,
            in: store
        )
        if let profile {
            UserDefaults.standard.set(
                profile.allowLockedQuickCapture,
                forKey: Self.lockedQuickCapturePreferenceKey
            )
        }
        state = .ready
    }

    private func recoverRestoreRollback(
        store: EncryptedRecordStore,
        archiveURL: URL,
        password: String,
        generation: Int,
        stateBeforeRestore: State
    ) async throws {
        // A fresh unstructured task does not inherit cancellation from the
        // failed restore, so recovery can finish its index rebuild and decode.
        let recoveryTask = Task { @MainActor [self] in
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            invalidateCommittedJournalProjection(
                invalidateRecentEntries: true
            )
            try await store.restorePortableArchive(
                from: archiveURL,
                password: password,
                observesCancellation: false
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            try await load(from: store, mode: .rollbackRecovery)
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            if profile != nil { try validateLoadedBook() }
        }
        try await recoveryTask.value
        guard ownsStoreGeneration(generation) else {
            throw AppModelError.locked
        }
        state = stateBeforeRestore
    }

    /// A restore candidate is never trial-applied to the live database. The
    /// temporary key exists only long enough to open a disposable SQLCipher
    /// file and is explicitly overwritten on every exit path.
    @discardableResult
    func validateRestoreCandidateInIsolation(
        from archiveURL: URL,
        password: String
    ) async throws -> RestoreCandidatePreviewValidation {
        try Task.checkCancellation()
        let directoryURL = restoreValidationDirectoryURL
        let databaseURL = directoryURL.appendingPathComponent(
            "candidate.sqlite3",
            isDirectory: false
        )
        try prepareRestoreValidationDirectory(directoryURL)
        var validationKey = Self.temporaryRestoreValidationKey()
        defer { validationKey.resetBytes(in: 0..<validationKey.count) }
        let validationStore = try openRestoreValidationStore(
            databaseURL: databaseURL,
            directoryURL: directoryURL,
            key: validationKey
        )
        validationKey.resetBytes(in: 0..<validationKey.count)

        var validationResult: RestoreCandidatePreviewValidation?
        var validationFailure: (any Error)?
        do {
            validationResult = try await validateRestoreCandidate(
                in: validationStore,
                archiveURL: archiveURL,
                password: password
            )
        } catch {
            validationFailure = error
        }

        await validationStore.close()
        do {
            try Self.removeRestoreValidationDirectory(directoryURL)
        } catch {
            // A disposable plaintext path must not be left behind even though
            // its contents are encrypted. Treat cleanup failure as a failed
            // validation and keep the live book untouched.
            validationFailure = AppModelError.invalidBook
        }
        if let validationFailure { throw validationFailure }
        guard let validationResult else { throw AppModelError.invalidBook }
        return validationResult
    }

    private func prepareRestoreValidationDirectory(_ directoryURL: URL) throws {
        do {
            // Reuse one exact owned directory so crash leftovers cannot
            // accumulate as unbounded UUID-named validation directories.
            try Self.removeRestoreValidationDirectory(directoryURL)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw AppModelError.invalidBook
        }
    }

    private func openRestoreValidationStore(
        databaseURL: URL,
        directoryURL: URL,
        key: Data
    ) throws -> EncryptedRecordStore {
        do {
            return try EncryptedRecordStore(databaseURL: databaseURL, key: key)
        } catch {
            let creationFailure = error
            do {
                try Self.removeRestoreValidationDirectory(directoryURL)
            } catch {
                throw AppModelError.invalidBook
            }
            throw creationFailure
        }
    }

    func validateRestoreCandidate(
        in store: EncryptedRecordStore,
        archiveURL: URL,
        password: String
    ) async throws -> RestoreCandidatePreviewValidation {
        let archiveMetadata = try await store.restorePortableArchive(
            from: archiveURL,
            password: password
        )
        try Task.checkCancellation()
        let metrics = try await store.storageMetrics()
        guard metrics.recordCount
                <= RestoreCandidateValidator.maximumCandidateRecordCount,
              metrics.payloadByteCount
                <= RestoreCandidateValidator.maximumBackupStoredPayloadByteCount,
              metrics.recordIDByteCount
                <= RestoreCandidateValidator.maximumAggregateRecordIDByteCount,
              metrics.collectionByteCount
                <= RestoreCandidateValidator.maximumAggregateCollectionByteCount else {
            throw AppModelError.invalidBook
        }

        let validationModel = AppModel(
            restoreValidationStore: store,
            lockedCaptureStore: lockedCaptureStore,
            receiptRecognizer: receiptRecognizer
        )
        try await validationModel.load(from: store, mode: .restoreValidation)
        guard validationModel.profile != nil else {
            throw AppModelError.invalidBook
        }
        try validationModel.validateLoadedBook()
        let entryMetadata = try await RestoreCandidateValidator.validateRelationships(
            profile: validationModel.profile,
            accounts: validationModel.accounts,
            budgetNodes: validationModel.budgetNodes,
            scheduledTransactions: validationModel.scheduledTransactions,
            investmentHoldings: validationModel.investmentHoldings,
            netWorthSnapshots: validationModel.netWorthSnapshots,
            quickLogDraft: validationModel.quickLogDraft,
            in: store
        )
        try Task.checkCancellation()
        let countSnapshot = try await store.recordCountSnapshot()
        let currencies = validationModel.restorePreviewCurrencyCodes(
            journalCurrencies: entryMetadata.currencies
        )
        return RestoreCandidatePreviewValidation(
            archiveMetadata: archiveMetadata,
            countSnapshot: countSnapshot,
            entryMetadata: entryMetadata,
            currencies: currencies,
            quarantinedRecordCount: validationModel.recoveryIssueCount,
            reportingTimeZoneIdentifier:
                validationModel.profile?.reportingTimeZoneIdentifier ?? "GMT"
        )
    }

    static func temporaryRestoreValidationKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    var restoreValidationDirectoryURL: URL {
        // Dependency-injected test/preview models share the host temporary
        // directory, so isolate them by their already-unique database parent.
        // Production has no injected URL and always uses the single `primary`
        // location scavenged by `start()` and before every restore.
        let discriminator = databaseURLForErase?
            .deletingLastPathComponent()
            .lastPathComponent ?? "primary"
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "MoneyUp-RestoreValidation-\(discriminator)",
            isDirectory: true
        )
    }

    static func removeRestoreValidationDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func removeLegacyRestoreValidationDirectories() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let prefix = "MoneyUp-RestoreValidation-"
        let children = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            // Old builds used UUID.uuidString verbatim. Restrict cleanup to
            // that exact canonical shape so no unrelated temporary directory
            // sharing the human-readable prefix can ever be removed.
            guard let id = UUID(uuidString: suffix),
                  id.uuidString == suffix,
                  try child.resourceValues(forKeys: [.isDirectoryKey])
                      .isDirectory == true else {
                continue
            }
            try FileManager.default.removeItem(at: child)
        }
    }
}
