import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct OpenedDatabaseStore: Sendable {
    let store: EncryptedRecordStore
    let unlockToFirstUsefulContentInterval: MoneyUpPerformanceInterval?
}

typealias DatabaseStoreOpener = @Sendable (
    _ databaseURL: URL
) async throws -> OpenedDatabaseStore

enum DatabaseStoreOpeners {
    /// Preserves the production boundary exactly: Keychain access and SQLCipher
    /// opening stay off the main actor, and key bytes are overwritten on exit.
    static let production: DatabaseStoreOpener = { databaseURL in
        let performanceInterval = MoneyUpPerformanceSignposts.begin(.unlock)
        defer { MoneyUpPerformanceSignposts.end(performanceInterval) }
        return try await Task.detached(priority: .userInitiated) {
            var key = try DatabaseKeyStore.loadOrCreateKey(
                databaseURL: databaseURL
            )
            defer { key.resetBytes(in: 0..<key.count) }
            // Keychain has returned, so user response time is excluded from
            // the Golden journey while SQLCipher open, validation, model
            // publication, and the first visible Today content remain inside.
            let usefulContentInterval = MoneyUpPerformanceSignposts.begin(
                .unlockToFirstUsefulContent
            )
            var transfersUsefulContentInterval = false
            defer {
                if !transfersUsefulContentInterval {
                    MoneyUpPerformanceSignposts.end(
                        usefulContentInterval,
                        outcome: .failure
                    )
                }
            }
            let opened = OpenedDatabaseStore(
                store: try EncryptedRecordStore(
                    databaseURL: databaseURL,
                    key: key
                ),
                unlockToFirstUsefulContentInterval: usefulContentInterval
            )
            transfersUsefulContentInterval = true
            return opened
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

/// Ephemeral output from the on-device Vision pass.
///
/// OCR text and confidence are never persisted. Keeping the aggregate quality
/// beside the lines lets the pure receipt parser lower the confidence of every
/// proposed field when Vision itself was uncertain.
struct ReceiptRecognitionResult: Equatable, Sendable,
    ExpressibleByArrayLiteral {
    let lines: [String]
    let meanConfidence: Float?
    /// Conservative Vision confidence for each line in `lines`.
    ///
    /// A field candidate must use its own line's quality instead of allowing
    /// unrelated high-confidence header text to raise a weak amount or date.
    /// `nil` preserves compatibility with injected recognizers that only
    /// provide document-wide quality.
    let lineConfidences: [Float]?

    init(
        lines: [String],
        meanConfidence: Float? = nil,
        lineConfidences: [Float]? = nil
    ) {
        self.lines = lines
        self.meanConfidence = meanConfidence
        self.lineConfidences = lineConfidences?.count == lines.count
            ? lineConfidences : nil
    }

    init(arrayLiteral elements: String...) {
        self.init(lines: elements)
    }
}

typealias ReceiptLineRecognizer = @Sendable (Data) async throws
    -> ReceiptRecognitionResult

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

/// FIFO serialization for whole-profile writes. Every mutation re-reads the
/// latest committed profile after acquiring the serializer, so a delayed
/// setting write cannot restore an older value for an unrelated field.
actor ProfileMutationSerializer {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
