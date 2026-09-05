import Foundation
import MoneyUpPersistence

/// One MainActor-owned buffer keeps Swift `Data` copy-on-write from defeating
/// the explicit wipe after an unstructured recovery commit has completed.
@MainActor
private final class EphemeralKeyCliffRecoveryKey {
    var bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    func reset() {
        bytes.resetBytes(in: 0..<bytes.count)
    }
}

extension AppModel {
    /// Publishes one complete missing-key transition and refreshes only the
    /// separately encrypted inbox metadata needed by its recovery UI.
    func enterMissingDeviceBoundKeyRecovery(
        _ error: DatabaseKeyStoreError
    ) async {
        requestedQuickLogMode = nil
        disableBudgetWidgetSnapshot()
        clearDecodedState()
        startupFailureKind = .missingDeviceBoundKey
        await refreshLockedCaptureStateForKeyCliffRecovery()
        finishFailedStartup(
            message: safeUserMessage(for: error, context: .unlock)
        )
    }

    /// Normal startup owns recovery resumption so a process interruption after
    /// the durable marker can never expose onboarding or a mixed artifact set.
    func openAndFinishStartupIncludingKeyCliffRecovery(
        databaseURL: URL
    ) async throws {
        let isResuming = KeyCliffRecoveryTransaction
            .hasPendingManifest(for: databaseURL)
        let quickActionBoundaryEpoch = try quickActionBoundaryForKeyCliffResume(
            isResuming
        )
        var quickActionRecoveryWasValidated = false
        defer {
            finishQuickActionBoundary(
                quickActionBoundaryEpoch,
                validatedRecovery: quickActionRecoveryWasValidated
            )
        }
        if isResuming {
            // The marker is a hard old-book/new-book boundary. Clear every
            // externally visible request/projection before touching either
            // artifact set, including an authentication-cancelled resume.
            startupFailureKind = .missingDeviceBoundKey
            requestedQuickLogMode = nil
            disableBudgetWidgetSnapshot()
            if try KeyCliffRecoveryTransaction.phase(for: databaseURL) == .rollingBack {
                try keyCliffRecoveryKeyAccess.delete()
                try KeyCliffRecoveryTransaction.restoreOriginal(for: databaseURL)
                throw DatabaseKeyStoreError.missingDeviceBoundKey
            }
            try KeyCliffRecoveryTransaction.installCandidate(for: databaseURL)
        } else {
            keyCliffRecoveryResidueScavenger(databaseURL)
        }
        do {
            let openedDatabase = try await openDatabaseStore(databaseURL)
            adoptUnlockToFirstUsefulContentInterval(openedDatabase.unlockToFirstUsefulContentInterval)
            let openedStore = openedDatabase.store
            storeGeneration &+= 1
            store = openedStore
            if isResuming {
                // The durable marker still owns authority here. Decode and
                // validate without publishing the candidate's preferences or
                // applying normal-startup recovery conveniences before complete.
                try await load(from: openedStore, mode: .restoreValidation)
                let hasProfile = try await validateLoadedStartupBook(in: openedStore)
                // Recheck the separately encrypted inbox at the final durable
                // boundary. A capture that appeared after initial consent can
                // belong only to the inaccessible book and must never cross
                // into the archive-restored candidate.
                try await requireEmptyLockedCaptureInbox()
                await lifecycleHooks.checkpoint(.afterKeyCliffValidationBeforeCompletion)
                try KeyCliffRecoveryTransaction.complete(for: databaseURL)
                startupFailureKind = nil
                await publishValidatedStartupBookAfterIrreversibleRecovery(
                    in: openedStore, hasProfile: hasProfile
                )
                refreshBudgetWidgetSnapshot()
            } else {
                try await load(from: openedStore)
                try await finishLoadedStartup(in: openedStore)
            }
        } catch let error as DatabaseKeyStoreError
            where error == .authenticationCancelled {
            // Preserve both candidate and rollback when device authentication
            // is cancelled; this is not consent to discard either book.
            throw error
        } catch {
            guard isResuming else { throw error }
            await store?.close()
            store = nil
            storeGeneration &+= 1
            clearDecodedState()
            disableBudgetWidgetSnapshot()
            do {
                try KeyCliffRecoveryTransaction.beginRollback(for: databaseURL)
                try keyCliffRecoveryKeyAccess.delete()
                try KeyCliffRecoveryTransaction.restoreOriginal(for: databaseURL)
            } catch {
                throw AppModelError.restoreRecoveryFailed
            }
            throw DatabaseKeyStoreError.missingDeviceBoundKey
        }
        quickActionRecoveryWasValidated = isResuming
    }

    private func quickActionBoundaryForKeyCliffResume(
        _ isResuming: Bool
    ) throws -> UInt64? {
        guard isResuming else { return nil }
        return try beginAuthoritativeQuickActionBoundary()
    }

    /// Rebuilds a live book from the exact previewed ciphertext when the old
    /// SQLCipher key has been destroyed. The ticket is copied and reverified
    /// before generating a key or publishing any recovery transaction state.
    func recoverMissingDeviceBoundKey(
        _ ticket: RestorePreviewTicket,
        password: String
    ) async throws {
        guard startupFailureKind == .missingDeviceBoundKey,
              store == nil,
              case .failed = state else {
            throw AppModelError.locked
        }
        let quickActionBoundaryEpoch = try beginKeyCliffRecoveryMutation()
        var quickActionRecoveryWasValidated = false
        defer {
            finishBookReplacementMutation()
            finishQuickActionBoundary(
                quickActionBoundaryEpoch,
                validatedRecovery: quickActionRecoveryWasValidated
            )
        }
        disableBudgetWidgetSnapshot()

        try await requireEmptyLockedCaptureInbox()
        try Task.checkCancellation()
        let databaseURL = try keyCliffLiveDatabaseURL()
        guard keyCliffHasSurvivingCiphertext(at: databaseURL) else {
            throw AppModelError.missingRecord
        }
        try Self.removeRestoreTemporaryArchive(restoreCommitArchiveURL)
        let archiveURL = try await RestoreArchiveStaging.verifiedCommitCopy(
            for: ticket,
            to: restoreCommitArchiveURL
        )
        defer { try? Self.removeRestoreTemporaryArchive(archiveURL) }
        try Task.checkCancellation()
        let recoveryKey: EphemeralKeyCliffRecoveryKey
        do {
            recoveryKey = EphemeralKeyCliffRecoveryKey(
                try keyCliffRecoveryKeyAccess.generate()
            )
        } catch {
            throw error
        }
        defer { recoveryKey.reset() }
        guard recoveryKey.bytes.count == 32 else {
            throw DatabaseKeyStoreError.invalidStoredKey
        }
        do {
            try KeyCliffRecoveryTransaction.prepareCandidateDirectory(
                for: databaseURL
            )
        } catch {
            KeyCliffRecoveryTransaction.scavengeUncommittedCandidate(
                for: databaseURL
            )
            throw error
        }
        try await buildKeyCliffCandidate(
            archiveURL: archiveURL,
            password: password,
            databaseURL: databaseURL,
            recoveryKey: recoveryKey
        )
        do {
            try KeyCliffRecoveryTransaction.publishManifest(for: databaseURL)
            try Task.checkCancellation()
        } catch {
            try? KeyCliffRecoveryTransaction.removeAll(for: databaseURL)
            throw error
        }

        // Once the key is stored, ignore caller cancellation and reach either
        // a complete new book or a complete restoration of old ciphertext.
        let commitTask = Task { @MainActor [self, recoveryKey] in
            try await commitKeyCliffCandidate(
                databaseURL: databaseURL,
                recoveryKey: recoveryKey
            )
        }
        try await commitTask.value
        quickActionRecoveryWasValidated = true
    }

    private func beginKeyCliffRecoveryMutation() throws -> UInt64 {
        let epoch = try beginAuthoritativeQuickActionBoundary()
        do {
            try beginLifecycleMutation(invalidatesJournalProjection: false)
        } catch {
            quickActionRouteBroker.endAuthoritativeBoundary(epoch)
            throw error
        }
        isWorking = true
        isBookReplacementInProgress = true
        return epoch
    }

    private func buildKeyCliffCandidate(
        archiveURL: URL,
        password: String,
        databaseURL: URL,
        recoveryKey: EphemeralKeyCliffRecoveryKey
    ) async throws {
        let candidateURL = KeyCliffRecoveryTransaction
            .candidateDatabaseURL(for: databaseURL)
        let candidateStore: EncryptedRecordStore
        do {
            candidateStore = try await openDatabaseStoreWithKey(
                candidateURL,
                recoveryKey.bytes
            )
        } catch {
            try? KeyCliffRecoveryTransaction.removeAll(for: databaseURL)
            throw error
        }

        var candidateFailure: (any Error)?
        do {
            _ = try await validateRestoreCandidate(
                in: candidateStore,
                archiveURL: archiveURL,
                password: password
            )
        } catch {
            candidateFailure = error
        }
        await candidateStore.close()
        guard let candidateFailure else { return }
        try? KeyCliffRecoveryTransaction.removeAll(for: databaseURL)
        throw candidateFailure
    }

    private func commitKeyCliffCandidate(
        databaseURL: URL,
        recoveryKey: EphemeralKeyCliffRecoveryKey
    ) async throws {
        var keyWasStored = false
        do {
            try keyCliffRecoveryKeyAccess.store(recoveryKey.bytes)
            keyWasStored = true
            try KeyCliffRecoveryTransaction.installCandidate(
                for: databaseURL
            )
            let openedStore = try await openDatabaseStoreWithKey(
                databaseURL,
                recoveryKey.bytes
            )
            storeGeneration &+= 1
            store = openedStore
            do {
                try await load(from: openedStore, mode: .restoreValidation)
                let hasProfile = try await validateLoadedStartupBook(
                    in: openedStore
                )
                try await requireEmptyLockedCaptureInbox()
                await lifecycleHooks.checkpoint(
                    .afterKeyCliffValidationBeforeCompletion
                )
                try KeyCliffRecoveryTransaction.complete(for: databaseURL)
                startupFailureKind = nil
                await publishValidatedStartupBookAfterIrreversibleRecovery(
                    in: openedStore,
                    hasProfile: hasProfile
                )
            } catch {
                await openedStore.close()
                store = nil
                storeGeneration &+= 1
                throw error
            }
        } catch {
            try rollbackFailedKeyCliffCommit(
                databaseURL: databaseURL,
                keyWasStored: keyWasStored
            )
            throw error
        }
    }

    private func rollbackFailedKeyCliffCommit(
        databaseURL: URL,
        keyWasStored: Bool
    ) throws {
        clearDecodedState()
        disableBudgetWidgetSnapshot()
        startupFailureKind = .missingDeviceBoundKey
        state = .failed(
            AppLocalization.string("error.missing_device_bound_key")
        )
        do {
            try KeyCliffRecoveryTransaction.beginRollback(
                for: databaseURL
            )
            if keyWasStored { try keyCliffRecoveryKeyAccess.delete() }
            try KeyCliffRecoveryTransaction.restoreOriginal(for: databaseURL)
        } catch {
            throw AppModelError.restoreRecoveryFailed
        }
    }

    private func keyCliffLiveDatabaseURL() throws -> URL {
        if let databaseURLForErase { return databaseURLForErase }
        return try Self.databaseURL()
    }

    func hasPendingKeyCliffRecoveryTransaction() throws -> Bool {
        try KeyCliffRecoveryTransaction.hasPendingManifest(
            for: keyCliffLiveDatabaseURL()
        )
    }

    private func keyCliffHasSurvivingCiphertext(at databaseURL: URL) -> Bool {
        let exists = DatabaseKeyCreationPolicy.artifactURLs(for: databaseURL)
            .map { FileManager.default.fileExists(atPath: $0.path) }
        return !DatabaseKeyCreationPolicy.mayCreateKey(
            databaseExists: exists[0],
            writeAheadLogExists: exists[1],
            sharedMemoryExists: exists[2]
        )
    }
}
