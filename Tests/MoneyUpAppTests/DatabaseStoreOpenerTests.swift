import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class DatabaseStoreOpenerTests: XCTestCase {
    @MainActor
    func testAuthenticatedKeyAndSQLCipherOpenNeverRunOnMainThread() async throws {
        XCTAssertTrue(Thread.isMainThread)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("moneyup.sqlite")
        let expectedKey = Data(repeating: 0xA5, count: 32)
        let execution = StoreOpenExecutionRecorder()
        let opener = DatabaseStoreOpeners.make(
            keyLoader: { _ in
                execution.record(.authenticatedKey, onMainThread: Thread.isMainThread)
                return expectedKey
            },
            storeFactory: { url, key in
                execution.record(.sqlCipherOpen, onMainThread: Thread.isMainThread)
                guard key == expectedKey else {
                    throw DatabaseKeyStoreError.invalidStoredKey
                }
                return try EncryptedRecordStore(databaseURL: url, key: key)
            }
        )

        let opened = try await opener(databaseURL)
        if let interval = opened.unlockToFirstUsefulContentInterval {
            MoneyUpPerformanceSignposts.end(interval, outcome: .cancelled)
        }
        await opened.store.close()

        XCTAssertEqual(
            execution.snapshot(),
            [
                StoreOpenExecution(step: .authenticatedKey, onMainThread: false),
                StoreOpenExecution(step: .sqlCipherOpen, onMainThread: false)
            ]
        )
    }

    @MainActor
    func testEraseTombstoneReadNeverRunsOnMainThreadDuringLaunch() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let execution = ThreadExecutionRecorder()
        let access = DataEraseIntentAccess(
            isPending: {
                execution.record(onMainThread: Thread.isMainThread)
                return false
            },
            markPending: {},
            clear: {}
        )

        let isPending = try await access.isPendingWithoutBlockingLaunch()
        XCTAssertFalse(isPending)
        XCTAssertEqual(execution.snapshot(), [false])
    }
}

private enum StoreOpenStep: Equatable, Sendable {
    case authenticatedKey
    case sqlCipherOpen
}

private struct StoreOpenExecution: Equatable, Sendable {
    let step: StoreOpenStep
    let onMainThread: Bool
}

private final class StoreOpenExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var executions: [StoreOpenExecution] = []

    func record(_ step: StoreOpenStep, onMainThread: Bool) {
        lock.withLock {
            executions.append(
                StoreOpenExecution(step: step, onMainThread: onMainThread)
            )
        }
    }

    func snapshot() -> [StoreOpenExecution] {
        lock.withLock { executions }
    }
}

private final class ThreadExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadFlags: [Bool] = []

    func record(onMainThread: Bool) {
        lock.withLock { mainThreadFlags.append(onMainThread) }
    }

    func snapshot() -> [Bool] {
        lock.withLock { mainThreadFlags }
    }
}
