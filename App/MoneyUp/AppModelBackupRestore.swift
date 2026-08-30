import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
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

    /// Restores only after the candidate has passed the exact encrypted-store
    /// and domain load used by the app in an isolated temporary database.
    /// Cancellation and deterministic lifecycle interruption remain entirely
    /// before the one live replacement transaction.
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
        guard !isWorking,
              !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !isJournalMutationInProgress else {
            throw AppModelError.transactionInProgress
        }
        isWorking = true
        goalMutationBarrierClosed = true
        await waitForGoalMutationDrain()
        isLifecycleMutationInProgress = true
        invalidateInFlightJournalProjection()
        defer { finishExclusiveDataLifecycleMutation() }

        // A cancelled debounce can already be inside its store operation.
        // Drain it before taking the rollback snapshot so no pre-restore draft
        // can wake and overwrite the restored logical book afterward.
        await finishPendingQuickLogDraftWrite()
        let restoreStore = try requireStore()
        // A wrong password, malformed archive, or failed candidate validation
        // leaves the old book authoritative. Persist the newest in-memory form
        // before parsing untrusted input so cancelling its debounce cannot turn
        // a harmless failed restore into later power-loss data loss.
        try await flushQuickLogDraftForBackup(to: restoreStore)

        // The redacted inbox is outside the portable archive and has no book
        // identity. Keeping it across replacement could apply old-book input
        // to the restored book; dropping it would lose user input.
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

        let generation = storeGeneration
        let stateBeforeRestore = state
        try await validateRestoreCandidateInIsolation(
            from: archiveURL,
            password: password
        )
        try Task.checkCancellation()

        let rollbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Rollback-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        let rollbackPassword = UUID().uuidString + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: rollbackURL) }
        try await restoreStore.exportPortableArchive(
            to: rollbackURL,
            password: rollbackPassword
        )
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }

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
            try Task.checkCancellation()
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            try await load(from: restoreStore, mode: .restoreValidation)
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
                in: restoreStore
            )
            if let profile {
                UserDefaults.standard.set(
                    profile.allowLockedQuickCapture,
                    forKey: Self.lockedQuickCapturePreferenceKey
                )
            }
            state = .ready
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
                // `Task.init` creates a fresh unstructured task, so cancellation
                // of the failed restore is not inherited. Recovery must remain
                // uncancelled through both index rebuilding and domain decode:
                // those paths deliberately observe their current task's state.
                let rollbackRecoveryTask = Task { @MainActor [self] in
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    // Candidate loading may have partially assigned decoded
                    // state. Keep every projection unavailable across the
                    // rollback transaction; `load` republishes only a coherent
                    // book.
                    invalidateCommittedJournalProjection(
                        invalidateRecentEntries: true
                    )
                    try await restoreStore.restorePortableArchive(
                        from: rollbackURL,
                        password: rollbackPassword,
                        observesCancellation: false
                    )
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    try await load(from: restoreStore, mode: .rollbackRecovery)
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    if profile != nil { try validateLoadedBook() }
                }
                try await rollbackRecoveryTask.value
                guard ownsStoreGeneration(generation) else {
                    throw AppModelError.locked
                }
                state = stateBeforeRestore
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

    /// A restore candidate is never trial-applied to the live database. The
    /// temporary key exists only long enough to open a disposable SQLCipher
    /// file and is explicitly overwritten on every exit path.
    func validateRestoreCandidateInIsolation(
        from archiveURL: URL,
        password: String
    ) async throws {
        try Task.checkCancellation()
        let directoryURL = restoreValidationDirectoryURL
        let databaseURL = directoryURL.appendingPathComponent(
            "candidate.sqlite3",
            isDirectory: false
        )
        do {
            // Reuse one exact owned directory. A crash can leave it behind,
            // but the next validation removes it before any untrusted row is
            // copied, preventing unbounded UUID-directory accumulation.
            try Self.removeRestoreValidationDirectory(directoryURL)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw AppModelError.invalidBook
        }
        var validationKey = Self.temporaryRestoreValidationKey()
        defer { validationKey.resetBytes(in: 0..<validationKey.count) }

        let validationStore: EncryptedRecordStore
        do {
            validationStore = try EncryptedRecordStore(
                databaseURL: databaseURL,
                key: validationKey
            )
        } catch {
            let creationFailure = error
            do {
                try Self.removeRestoreValidationDirectory(directoryURL)
            } catch {
                throw AppModelError.invalidBook
            }
            throw creationFailure
        }
        validationKey.resetBytes(in: 0..<validationKey.count)

        var validationFailure: (any Error)?
        do {
            try await validationStore.restorePortableArchive(
                from: archiveURL,
                password: password
            )
            try Task.checkCancellation()

            let metrics = try await validationStore.storageMetrics()
            guard metrics.recordCount
                    <= RestoreCandidateValidator.maximumCandidateRecordCount,
                  metrics.payloadByteCount
                    <= RestoreCandidateValidator
                        .maximumBackupStoredPayloadByteCount,
                  metrics.recordIDByteCount
                    <= RestoreCandidateValidator
                        .maximumAggregateRecordIDByteCount,
                  metrics.collectionByteCount
                    <= RestoreCandidateValidator
                        .maximumAggregateCollectionByteCount else {
                throw AppModelError.invalidBook
            }

            let validationModel = AppModel(
                restoreValidationStore: validationStore,
                lockedCaptureStore: lockedCaptureStore,
                receiptRecognizer: receiptRecognizer
            )
            try await validationModel.load(
                from: validationStore,
                mode: .restoreValidation
            )
            guard validationModel.profile != nil else {
                throw AppModelError.invalidBook
            }
            try validationModel.validateLoadedBook()
            try await RestoreCandidateValidator.validateRelationships(
                profile: validationModel.profile,
                accounts: validationModel.accounts,
                budgetNodes: validationModel.budgetNodes,
                scheduledTransactions: validationModel.scheduledTransactions,
                investmentHoldings: validationModel.investmentHoldings,
                netWorthSnapshots: validationModel.netWorthSnapshots,
                quickLogDraft: validationModel.quickLogDraft,
                in: validationStore
            )
            try Task.checkCancellation()
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
