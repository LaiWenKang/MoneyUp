import Foundation

/// The redacted inbox is deliberately abstracted from `AppModel` so lifecycle
/// races can be exercised without touching the process-wide Keychain or the
/// production application-support directory.
protocol LockedCaptureStoring: Sendable {
    func all() async throws -> [LockedCapture]
    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int
    @discardableResult
    func remove(id: UUID) async throws -> Int
}

extension LockedCaptureStore: LockedCaptureStoring {}

enum AppModelLifecycleCheckpoint: Equatable, Sendable {
    case beforeJournalCommit
    case afterAccountWriteBeforeApply
    case afterCaptureDraftPersisted
    /// The candidate has passed isolated store and domain validation, but the
    /// live SQLCipher transaction has not started yet.
    case beforeRestoreCommit
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
