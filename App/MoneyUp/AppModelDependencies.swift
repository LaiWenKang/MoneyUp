import Foundation
import MoneyUpPersistence

typealias DatabaseStoreOpener = @Sendable (
    _ databaseURL: URL
) async throws -> EncryptedRecordStore

enum DatabaseStoreOpeners {
    /// Preserves the production boundary exactly: Keychain access and SQLCipher
    /// opening stay off the main actor, and key bytes are overwritten on exit.
    static let production: DatabaseStoreOpener = { databaseURL in
        try await Task.detached(priority: .userInitiated) {
            var key = try DatabaseKeyStore.loadOrCreateKey(
                databaseURL: databaseURL
            )
            defer { key.resetBytes(in: 0..<key.count) }
            return try EncryptedRecordStore(databaseURL: databaseURL, key: key)
        }.value
    }
}

/// The redacted inbox is deliberately abstracted from `AppModel` so lifecycle
/// races can be exercised without touching the process-wide Keychain or the
/// production application-support directory.
protocol LockedCaptureStoring: Sendable {
    func all() async throws -> [LockedCapture]
    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int
    @discardableResult
    func remove(id: UUID) async throws -> Int
    func eraseAll() async throws
}

extension LockedCaptureStore: LockedCaptureStoring {}

/// Injectable access to the durable erase tombstone. Production stores it in
/// the device-only Keychain; tests use closures so every interruption boundary
/// can be asserted without touching process-wide credentials.
struct DataEraseIntentAccess: Sendable {
    let isPending: @Sendable () throws -> Bool
    let markPending: @Sendable () throws -> Void
    let clear: @Sendable () throws -> Void

    static let production = DataEraseIntentAccess(
        isPending: { try DataEraseIntentStore.isPending() },
        markPending: { try DataEraseIntentStore.markPending() },
        clear: { try DataEraseIntentStore.clear() }
    )

    static let none = DataEraseIntentAccess(
        isPending: { false },
        markPending: {},
        clear: {}
    )
}

enum AppModelLifecycleCheckpoint: Equatable, Sendable {
    case beforeJournalCommit
    /// Every previously published journal-derived value has been made
    /// unavailable, while the durable store still contains the old journal.
    case afterJournalProjectionInvalidationBeforeCommit
    /// The journal transaction is durable, but no in-memory or derived
    /// projection has been allowed to publish the new state yet.
    case afterJournalCommitBeforeProjectionRefresh
    case afterAccountWriteBeforeApply
    case afterCaptureDraftPersisted
    /// The candidate has passed isolated store and domain validation, but the
    /// live SQLCipher transaction has not started yet.
    case beforeRestoreCommit
    /// The candidate replacement is durable, but candidate state has not been
    /// decoded into the live model yet.
    case afterRestoreCommitBeforeCandidateLoad
    case afterJournalProjectionReadBeforePublish
    case beforeNetWorthSnapshotCommit
    case beforeInvestmentCorrectionCommit
    case beforeScheduleMatchCommit
    case beforeScheduleMutationCommit
    case beforeSavingsGoalWrite
    case beforeQuickLogDraftWrite
    case beforeProfileWrite
}

/// Production uses the no-op checkpoint. Tests can suspend one exact boundary
/// and then trigger Lock or Erase deterministically, without sleeps or timing
/// assumptions.
struct AppModelLifecycleHooks: Sendable {
    let checkpoint: @Sendable (AppModelLifecycleCheckpoint) async -> Void

    static let none = AppModelLifecycleHooks { _ in }
}

typealias ReceiptLineRecognizer = @Sendable (Data) async throws -> [String]

/// FIFO serialization per goal ID. `@MainActor` methods may interleave at any
/// store await, so actor isolation of the model alone is not a transaction
/// boundary for read-modify-write goal mutations.
actor SavingsGoalMutationSerializer {
    private var held = Set<UUID>()
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ id: UUID) async {
        if held.insert(id).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    func release(_ id: UUID) {
        guard var queued = waiters[id], !queued.isEmpty else {
            waiters.removeValue(forKey: id)
            held.remove(id)
            return
        }
        let next = queued.removeFirst()
        if queued.isEmpty {
            waiters.removeValue(forKey: id)
        } else {
            waiters[id] = queued
        }
        next.resume()
    }
}
