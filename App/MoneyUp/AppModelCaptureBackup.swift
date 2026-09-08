import Foundation
import MoneyUpPersistence

/// A book-owned copy of an unfinished capture. Array position is persisted
/// explicitly because wall-clock changes must not reorder the capture inbox.
struct ArchivedLockedCapture: Codable, Equatable, Identifiable, Sendable {
    let capture: LockedCapture
    let position: Int
    var id: UUID { capture.id }

    var isStructurallyValid: Bool {
        capture.isStructurallyValid && position >= 0
            && position < RestoreCandidateValidator.maximumCandidateRecordCount
    }
}

extension AppModel {
    /// Protect both sources of unfinished input in the book being replaced.
    /// Key-cliff completion separately checks only the device inbox, since
    /// captures inside its authenticated candidate belong to the new book.
    func requireNoPendingCapturesForBookReplacement() async throws {
        try await requireEmptyLockedCaptureInbox()
        guard let store else { return }
        let captures = try await archivedLockedCaptures(in: store)
        pendingLockedCaptureCount = captures.count
        guard captures.isEmpty else { throw AppModelError.pendingLockedCaptures }
    }

    func archivedLockedCaptures(
        in captureStore: EncryptedRecordStore
    ) async throws -> [ArchivedLockedCapture] {
        let result = try await captureStore.fetchAllIdentifiedRecovering(
            ArchivedLockedCapture.self,
            from: .pendingLockedCaptures
        )
        guard result.issues.isEmpty,
              result.values.allSatisfy(\.isStructurallyValid),
              Set(result.values.map(\.capture.id)).count == result.values.count,
              Set(result.values.map(\.position)).count == result.values.count else {
            throw AppModelError.invalidBook
        }
        return result.values.sorted { $0.position < $1.position }
    }

    /// The book copy survives replacement-phone restore. The device inbox
    /// remains a second durable copy until the user reviews the capture.
    /// Stable capture IDs make repeated backups and interrupted promotion
    /// idempotent; conflicting copies fail without deleting either source.
    func pendingLockedCaptures(
        in captureStore: EncryptedRecordStore
    ) async throws -> [LockedCapture] {
        var captures = try await archivedLockedCaptures(in: captureStore)
            .map(\.capture)
        var byID = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0) })
        for capture in try await lockedCaptureStore.all() {
            if let existing = byID[capture.id] {
                guard existing == capture else { throw AppModelError.invalidBook }
            } else {
                captures.append(capture)
                byID[capture.id] = capture
            }
        }
        return captures
    }

    func preserveLockedCapturesForBackup(
        in backupStore: EncryptedRecordStore
    ) async throws {
        let captures: [LockedCapture]
        do {
            captures = try await pendingLockedCaptures(in: backupStore)
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
            throw error
        }
        guard captures.count <= RestoreCandidateValidator.maximumCandidateRecordCount else {
            throw AppModelError.invalidBook
        }
        let writes = try captures.enumerated().map { position, capture in
            try RecordWrite(
                ArchivedLockedCapture(capture: capture, position: position),
                id: capture.id.uuidString,
                in: .pendingLockedCaptures
            )
        }
        // SQLCipher commits the complete inbox copy before the archive starts.
        // Export failure never consumes the draft or the device inbox.
        if !writes.isEmpty { try await backupStore.write(writes) }
        pendingLockedCaptureCount = captures.count
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
    }

    func removePendingLockedCapture(
        id: UUID,
        in captureStore: EncryptedRecordStore
    ) async throws -> Int {
        // The editable draft or matching journal entry is already durable.
        // If either deletion fails, its source ID makes promotion retryable.
        try await captureStore.remove(
            id: id.uuidString,
            from: .pendingLockedCaptures
        )
        try await lockedCaptureStore.remove(id: id)
        return try await pendingLockedCaptures(in: captureStore).count
    }
}
