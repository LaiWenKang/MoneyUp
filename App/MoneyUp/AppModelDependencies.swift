import Foundation

/// The redacted inbox is deliberately abstracted from `AppModel` so lifecycle
/// races can be exercised without touching the process-wide Keychain or the
/// production application-support directory.
protocol LockedCaptureStoring: Sendable {
    func all() async throws -> [LockedCapture]
    func append(_ capture: LockedCapture) async throws
    func remove(id: UUID) async throws
}

extension LockedCaptureStore: LockedCaptureStoring {}

enum AppModelLifecycleCheckpoint: Equatable, Sendable {
    case beforeJournalCommit
    case afterAccountWriteBeforeApply
    case afterCaptureDraftPersisted
}

/// Production uses the no-op checkpoint. Tests can suspend one exact boundary
/// and then trigger Lock or Erase deterministically, without sleeps or timing
/// assumptions.
struct AppModelLifecycleHooks: Sendable {
    let checkpoint: @Sendable (AppModelLifecycleCheckpoint) async -> Void

    static let none = AppModelLifecycleHooks { _ in }
}

typealias ReceiptLineRecognizer = @Sendable (Data) async throws -> [String]
