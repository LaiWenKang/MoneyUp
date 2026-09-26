import Foundation
import MoneyUpCore
@testable import MoneyUp
import XCTest

final class AutomaticUnlockTests: XCTestCase {
    @MainActor
    func testAutomaticAttemptIsSingleFlightAndCancellationRequiresExplicitRetry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AuthenticationAttemptGate()
        let model = fixture.model(openDatabaseStore: { _ in
            await gate.enter()
            throw DatabaseKeyStoreError.authenticationCancelled
        })
        model.lock()
        model.sceneDidBecomeActive()
        let first = Task { await model.unlockAutomaticallyIfNeeded() }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.isWorking)
        let duplicate = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(duplicate)
        // The native prompt's own inactive/active cycle must not rearm it.
        model.sceneDidBecomeInactive()
        model.sceneDidBecomeActive()
        await gate.release()
        _ = await first.value
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
        let retriedAutomatically = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(retriedAutomatically)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 1)
        // An explicit retry remains usable after cancellation.
        _ = await model.start()
        let explicitAttempts = await gate.attempts
        XCTAssertEqual(explicitAttempts, 2)
    }

    @MainActor
    func testCancellationInEitherSceneCallbackOrderDoesNotRearm() {
        for activeFirst in [false, true] {
            let model = AppModel()
            model.sceneDidBecomeActive()
            model.isStarting = true
            model.automaticUnlockIsPending = false
            model.sceneDidBecomeInactive()
            if activeFirst { model.sceneDidBecomeActive() }
            model.finishCancelledAuthentication()
            model.isStarting = false
            if !activeFirst { model.sceneDidBecomeActive() }
            XCTAssertFalse(model.automaticUnlockIsPending)
            XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
            model.sceneDidBecomeInactive()
            model.sceneDidEnterBackground()
            model.sceneDidBecomeActive()
            XCTAssertTrue(model.automaticUnlockIsPending)
        }
    }

    @MainActor
    func testManualLockWaitsForNewVisitAndInTimeReturnDoesNotAuthenticate() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(profile: UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60))
        let now = Date()
        model.sceneDidBecomeActive(at: now)
        model.sceneDidBecomeInactive(at: now)
        model.sceneDidBecomeActive(at: now.addingTimeInterval(30))
        let inTime = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(inTime)
        XCTAssertEqual(model.state, .ready)
        model.lockManually()
        let afterManualLock = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(afterManualLock)
        XCTAssertEqual(model.state, .locked)
        model.sceneDidBecomeInactive(at: now.addingTimeInterval(31))
        model.sceneDidEnterBackground(at: now.addingTimeInterval(32))
        model.sceneDidBecomeActive(at: now.addingTimeInterval(33))
        XCTAssertTrue(model.automaticUnlockIsPending)
        await model.waitForPendingStoreClose()
    }

    @MainActor
    func testExpiredReturnArmsUnlockButInactiveCannotPromptAndAWidgetTapGetsTheNormalUnlock() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AuthenticationAttemptGate()
        await gate.release()
        let model = fixture.model(
            profile: UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 0),
            openDatabaseStore: { _ in
                await gate.enter()
                throw DatabaseKeyStoreError.authenticationCancelled
            }
        )
        model.sceneDidBecomeActive()
        model.sceneDidBecomeInactive()
        let inactive = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(inactive)
        XCTAssertEqual(model.state, .locked)
        let noPromptWhileInactive = await gate.attempts
        XCTAssertEqual(noPromptWhileInactive, 0)
        // One Log: a widget tap waiting while locked gets the same single
        // automatic prompt as any expired return, not a separate locked form.
        model.requestedQuickLogMode = .expense
        model.sceneDidBecomeActive()
        _ = await model.unlockAutomaticallyIfNeeded()
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(model.automaticUnlockIsPending)
        XCTAssertEqual(model.state, .locked)
        let retriedAutomatically = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(retriedAutomatically)
        let finalAttempts = await gate.attempts
        XCTAssertEqual(finalAttempts, 1)
        await model.waitForPendingStoreClose()
    }
}

private actor AuthenticationAttemptGate {
    private(set) var attempts = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    private var released = false

    func enter() async {
        attempts += 1
        entered?.resume()
        entered = nil
        guard !released else { return }
        await withCheckedContinuation { pending = $0 }
    }

    func waitUntilEntered() async {
        guard attempts == 0 else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        released = true
        pending?.resume()
        pending = nil
    }
}
