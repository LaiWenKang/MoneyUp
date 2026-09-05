import CryptoKit
import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension AppModel {
    func scavengeRestorePreviewArtifacts() {
        for url in [
            restorePreviewValidationArchiveURL,
            restoreStagedArchiveURL,
            restoreCommitArchiveURL,
            restoreRollbackDirectoryURL,
        ] {
            try? Self.removeRestoreTemporaryArchive(url)
        }
    }

    func prepareEncryptedRestorePreview(
        from stagedArchiveURL: URL,
        password: String
    ) async throws -> RestorePreviewTicket {
        guard !password.isEmpty else {
            throw PortableArchiveError.authenticationFailed
        }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        isWorking = true
        defer {
            isWorking = false
            endLifecycleMutation()
        }

        let current = try await restorePreviewCurrentBook()
        try await requireEmptyLockedCaptureInbox()
        try Self.removeLegacyRestoreValidationDirectories()
        try Self.removeRestoreTemporaryArchive(
            restorePreviewValidationArchiveURL
        )
        let validationCopy = try await RestoreArchiveStaging.validationCopy(
            from: stagedArchiveURL,
            to: restorePreviewValidationArchiveURL
        )
        defer { try? FileManager.default.removeItem(at: validationCopy.url) }
        let candidate = try await validateRestoreCandidateInIsolation(
            from: validationCopy.url,
            password: password
        )
        let after = try await RestoreArchiveStaging.fingerprint(
            at: stagedArchiveURL
        )
        guard validationCopy.fingerprint == after else {
            throw AppModelError.restorePreviewChanged
        }

        let candidateSummary = RestorePreview.BookSummary(
            storedRecordCounts: candidate.countSnapshot.storedRecordCounts,
            entryDateSpan: Self.dateSpan(from: candidate.entryMetadata),
            currencies: candidate.currencies,
            quarantinedRecordCount: candidate.quarantinedRecordCount,
            reportingTimeZoneIdentifier:
                candidate.reportingTimeZoneIdentifier
        )
        return RestorePreviewTicket(
            preview: RestorePreview(
                archiveFormatVersion: candidate.archiveMetadata.archiveVersion,
                archiveSchemaVersion: candidate.archiveMetadata.schemaVersion,
                current: current,
                candidate: candidateSummary
            ),
            stagedArchiveURL: stagedArchiveURL,
            archiveFingerprint: validationCopy.fingerprint
        )
    }

    func restoreEncryptedBackup(
        _ ticket: RestorePreviewTicket,
        password: String
    ) async throws {
        if startupFailureKind == .missingDeviceBoundKey {
            try await recoverMissingDeviceBoundKey(
                ticket,
                password: password
            )
            return
        }
        let quickActionBoundaryEpoch = try beginRestoreMutation()
        var quickActionRecoveryWasValidated = false
        defer {
            finishBookReplacementMutation()
            finishQuickActionBoundary(
                quickActionBoundaryEpoch,
                validatedRecovery: quickActionRecoveryWasValidated
            )
        }
        await finishBeginningRestoreMutation()
        try Self.removeRestoreTemporaryArchive(restoreCommitArchiveURL)
        let commitURL = try await RestoreArchiveStaging.verifiedCommitCopy(
            for: ticket,
            to: restoreCommitArchiveURL
        )
        defer { try? FileManager.default.removeItem(at: commitURL) }
        try await restoreEncryptedBackupAfterVerifiedTicket(
            from: commitURL,
            password: password
        )
        quickActionRecoveryWasValidated = true
    }

    private func restorePreviewCurrentBook()
    async throws -> RestorePreview.CurrentBook {
        if startupFailureKind == .missingDeviceBoundKey {
            guard store == nil, case .failed = state else {
                throw AppModelError.locked
            }
            return .inaccessible
        }
        return .available(
            try await currentRestorePreviewSummary(in: requireStore())
        )
    }

    private func currentRestorePreviewSummary(
        in currentStore: EncryptedRecordStore
    ) async throws -> RestorePreview.BookSummary {
        let counts = try await currentStore.recordCountSnapshot()
        let entries = try await journalSnapshot(
            includeInvalidRelationships: false
        )
        let entryMetadata = try RestoreEntryPreviewMetadata.make(from: entries)
        return RestorePreview.BookSummary(
            storedRecordCounts: counts.storedRecordCounts,
            entryDateSpan: Self.dateSpan(from: entryMetadata),
            currencies: restorePreviewCurrencyCodes(
                journalCurrencies: entryMetadata.currencies
            ),
            quarantinedRecordCount: recoveryIssueCount,
            reportingTimeZoneIdentifier:
                profile?.reportingTimeZoneIdentifier ?? "GMT"
        )
    }

    func restorePreviewCurrencyCodes(
        journalCurrencies: [CurrencyCode]
    ) -> [CurrencyCode] {
        var result = Set(journalCurrencies)
        if let profile { result.insert(profile.baseCurrency) }
        result.formUnion(accounts.compactMap(\.currency))
        result.formUnion(budgetNodes.compactMap(\.limit?.currency))
        if let budgetConfigurationTimeline {
            result.insert(budgetConfigurationTimeline.currency)
        }
        result.formUnion(scheduledTransactions.map(\.amount.currency))
        result.formUnion(savingsGoals.map(\.target.currency))
        for rate in exchangeRates {
            result.insert(rate.baseCurrency)
            result.insert(rate.quoteCurrency)
        }
        for snapshot in netWorthSnapshots {
            result.formUnion(snapshot.amounts.map(\.money.currency))
            if let total = snapshot.estimatedBaseTotal {
                result.insert(total.currency)
            }
        }
        return result.sorted()
    }

    private static func dateSpan(
        from metadata: RestoreEntryPreviewMetadata
    ) -> RestorePreview.EntryDateSpan? {
        guard let oldest = metadata.oldestEntryDate,
              let newest = metadata.newestEntryDate else { return nil }
        return RestorePreview.EntryDateSpan(oldest: oldest, newest: newest)
    }

    var restorePreviewValidationArchiveURL: URL {
        restoreTemporaryArchiveURL(prefix: "MoneyUp-RestorePreview-")
    }

    var restoreStagedArchiveURL: URL {
        restoreTemporaryArchiveURL(prefix: "MoneyUp-RestoreStaged-")
    }

    var restoreCommitArchiveURL: URL {
        restoreTemporaryArchiveURL(prefix: "MoneyUp-RestoreCommit-")
    }

    var restoreRollbackArchiveURL: URL {
        restoreRollbackDirectoryURL.appendingPathComponent(
            "rollback.moneyup",
            isDirectory: false
        )
    }

    var restoreRollbackDirectoryURL: URL {
        restoreTemporaryArchiveURL(prefix: "MoneyUp-RestoreRollback-")
            .deletingPathExtension()
    }

    private func restoreTemporaryArchiveURL(prefix: String) -> URL {
        let discriminator = databaseURLForErase?
            .deletingLastPathComponent()
            .lastPathComponent ?? "primary"
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + discriminator + ".moneyup",
            isDirectory: false
        )
    }

    static func removeRestoreTemporaryArchive(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum RestoreArchiveStaging {
    private static let chunkByteCount = 64 * 1_024

    static func fingerprint(at url: URL) async throws -> RestoreArchiveFingerprint {
        let task = Task.detached(priority: .userInitiated) {
            try Self.fingerprintSynchronously(at: url)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func validationCopy(
        from source: URL,
        to destination: URL
    ) async throws -> (url: URL, fingerprint: RestoreArchiveFingerprint) {
        let task = Task.detached(priority: .userInitiated) {
            try Self.copyAndFingerprint(from: source, to: destination)
        }
        do {
            let fingerprint = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return (destination, fingerprint)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func verifiedCommitCopy(
        for ticket: RestorePreviewTicket,
        to destination: URL
    ) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) {
            try Self.copyAndFingerprint(
                from: ticket.stagedArchiveURL,
                to: destination
            )
        }
        do {
            let fingerprint = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard fingerprint == ticket.archiveFingerprint else {
                throw AppModelError.restorePreviewChanged
            }
            return destination
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func copyAndFingerprint(
        from source: URL,
        to destination: URL
    ) throws -> RestoreArchiveFingerprint {
        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true else {
            throw PortableArchiveError.invalidArchive
        }
        if let size = values.fileSize,
           !PortableArchive.isWithinArchiveByteLimit(size) {
            throw PortableArchiveError.archiveTooLarge
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        let byteCount = try BoundedFileReader.copy(
            from: handle,
            to: destination,
            maximumByteCount: PortableArchive.maximumArchiveByteCount,
            onChunk: { hasher.update(data: $0) }
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: destination.path
        )
        return RestoreArchiveFingerprint(
            byteCount: byteCount,
            sha256: Data(hasher.finalize())
        )
    }

    private static func fingerprintSynchronously(
        at url: URL
    ) throws -> RestoreArchiveFingerprint {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true else {
            throw PortableArchiveError.invalidArchive
        }
        if let size = values.fileSize,
           !PortableArchive.isWithinArchiveByteLimit(size) {
            throw PortableArchiveError.archiveTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try handle.read(upToCount: chunkByteCount),
              !chunk.isEmpty {
            try Task.checkCancellation()
            let (nextCount, overflow) = byteCount.addingReportingOverflow(
                chunk.count
            )
            guard !overflow,
                  PortableArchive.isWithinArchiveByteLimit(nextCount) else {
                throw PortableArchiveError.archiveTooLarge
            }
            hasher.update(data: chunk)
            byteCount = nextCount
        }
        return RestoreArchiveFingerprint(
            byteCount: byteCount,
            sha256: Data(hasher.finalize())
        )
    }
}
