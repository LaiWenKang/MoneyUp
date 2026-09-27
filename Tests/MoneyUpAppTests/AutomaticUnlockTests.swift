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

    /// A closed book (Lock now, or a cold start) still opens only through the
    /// device-bound key: a waiting widget tap gets the one normal prompt.
    @MainActor
    func testClosedBookArmsUnlockButInactiveCannotPromptAndAWidgetTapGetsTheNormalUnlock() async throws {
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
        model.lock()
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

    // MARK: Auto-lock cover (0.7.3)

    /// The auto-lock delay covers the open book instead of closing it; the
    /// automatic prompt asks for the device owner, never for the key.
    @MainActor
    func testExpiredReturnCoversTheOpenBookAndPromptsOnce() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let keyReads = AuthenticationAttemptGate()
        await keyReads.release()
        let model = fixture.model(
            profile: UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60),
            openDatabaseStore: { _ in
                await keyReads.enter()
                throw DatabaseKeyStoreError.authenticationCancelled
            }
        )
        let owner = ScriptedScreenAuthenticator(results: [false, true])
        model.screenAuthenticator = owner
        let now = Date()
        model.sceneDidBecomeActive(at: now)
        model.sceneDidBecomeInactive(at: now)
        model.sceneDidEnterBackground(at: now.addingTimeInterval(1))
        model.sceneDidBecomeActive(at: now.addingTimeInterval(61))
        XCTAssertEqual(model.state, .ready, "The book stays open behind the cover")
        XCTAssertNotNil(model.store)
        XCTAssertTrue(model.isScreenLocked)
        XCTAssertFalse(model.isLogOnlyAccess)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)

        let cancelled = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(cancelled)
        XCTAssertTrue(model.isScreenLocked, "A cancelled prompt keeps the cover")
        let retried = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(retried, "One automatic prompt per return")
        XCTAssertEqual(owner.attempts, 1)
        let explicit = await model.unlockScreen()
        XCTAssertTrue(explicit)
        XCTAssertFalse(model.isScreenLocked)
        XCTAssertEqual(owner.attempts, 2)
        let keyAttempts = await keyReads.attempts
        XCTAssertEqual(keyAttempts, 0, "Uncovering never reads the device-bound key")
    }

    /// A widget, control or Shortcut request while covered opens Log alone,
    /// with no prompt at all.
    @MainActor
    func testWidgetRequestWhileCoveredOpensLogWithoutAuthentication() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(profile: UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 0))
        let owner = ScriptedScreenAuthenticator(results: [true])
        model.screenAuthenticator = owner
        model.sceneDidBecomeActive()
        model.sceneDidBecomeInactive()
        XCTAssertTrue(model.isScreenLocked, "Immediately covers on leaving")
        model.requestedQuickLogMode = .expense
        XCTAssertTrue(model.isLogOnlyAccess)
        model.sceneDidBecomeActive()
        let prompted = await model.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(prompted)
        XCTAssertEqual(owner.attempts, 0, "Logging from a widget needs no Face ID")
        XCTAssertTrue(model.isScreenLocked, "Everything beyond Log stays covered")
        XCTAssertEqual(model.state, .ready)
    }

    /// A widget tap that arrives while the automatic prompt is on screen
    /// dismisses it and opens Log.
    @MainActor
    func testWidgetRequestDismissesAPromptAlreadyOnScreen() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(profile: UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 0))
        let owner = SuspendedScreenAuthenticator()
        model.screenAuthenticator = owner
        model.sceneDidBecomeActive()
        model.sceneDidBecomeInactive()
        model.sceneDidBecomeActive()
        let prompt = Task { await model.unlockAutomaticallyIfNeeded() }
        while !owner.isPrompting { await Task.yield() }
        model.requestedQuickLogMode = .income
        let unlocked = await prompt.value
        XCTAssertFalse(unlocked)
        XCTAssertTrue(owner.wasCancelled)
        XCTAssertTrue(model.isLogOnlyAccess)
        XCTAssertTrue(model.isScreenLocked)
    }

    /// Log-only access lasts for the visit that granted it; the next expired
    /// return shows the cover again. Lock now still closes the book.
    @MainActor
    func testLogOnlyAccessEndsWithTheNextExpiryAndManualLockClosesTheBook() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(profile: UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60))
        model.screenAuthenticator = ScriptedScreenAuthenticator(results: [])
        let now = Date()
        model.sceneDidBecomeActive(at: now)
        model.lockScreen()
        model.requestedQuickLogMode = .expense
        XCTAssertTrue(model.isLogOnlyAccess)
        let request = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(model.presentQuickLogRequest(request))
        model.consumeQuickLogRequest(request)
        XCTAssertTrue(model.isLogOnlyAccess, "Consuming the request keeps Log open")
        model.sceneDidBecomeInactive(at: now)
        model.sceneDidBecomeActive(at: now.addingTimeInterval(30))
        XCTAssertTrue(model.isLogOnlyAccess, "A return within the delay keeps Log")
        model.sceneDidBecomeInactive(at: now.addingTimeInterval(31))
        model.sceneDidBecomeActive(at: now.addingTimeInterval(120))
        XCTAssertTrue(model.isScreenLocked)
        XCTAssertFalse(model.isLogOnlyAccess, "The next expiry covers Log too")

        model.lockManually()
        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.store, "Lock now closes the book")
        XCTAssertFalse(model.isScreenLocked)
        XCTAssertFalse(model.isLogOnlyAccess)
        await model.waitForPendingStoreClose()
    }

    /// Leaving MoneyUp while the Face ID prompt is up cancels it. That visit
    /// still counts, so Log-only access ends at the next expiry.
    @MainActor
    func testLeavingDuringThePromptStillStartsTheVisitClock() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(profile: UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60))
        let owner = SuspendedScreenAuthenticator()
        model.screenAuthenticator = owner
        model.sceneDidBecomeActive()
        model.lockScreen()
        model.requestedQuickLogMode = .expense
        let request = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(model.presentQuickLogRequest(request))
        model.consumeQuickLogRequest(request)
        XCTAssertTrue(model.isLogOnlyAccess)
        let prompt = Task { await model.unlockScreen() }
        while !owner.isPrompting { await Task.yield() }
        model.sceneDidBecomeInactive()
        model.sceneDidEnterBackground()
        XCTAssertNil(model.leftActiveAt, "The prompt's own inactivity is not a visit")
        owner.cancel()
        let unlocked = await prompt.value
        XCTAssertFalse(unlocked)
        let leftAt = try XCTUnwrap(model.leftActiveAt, "A cancelled prompt in the background starts the clock")
        model.sceneDidBecomeActive(at: leftAt.addingTimeInterval(120))
        XCTAssertTrue(model.isScreenLocked)
        XCTAssertFalse(model.isLogOnlyAccess, "Log-only access ends with that visit")
    }
}

@MainActor
private final class ScriptedScreenAuthenticator: ScreenAuthenticating {
    private var results: [Bool]
    private(set) var attempts = 0
    init(results: [Bool]) { self.results = results }
    func authenticate() async -> Bool {
        attempts += 1
        return results.isEmpty ? false : results.removeFirst()
    }
    func cancel() {}
}

@MainActor
private final class SuspendedScreenAuthenticator: ScreenAuthenticating {
    private var pending: CheckedContinuation<Bool, Never>?
    private(set) var isPrompting = false
    private(set) var wasCancelled = false
    func authenticate() async -> Bool {
        isPrompting = true
        return await withCheckedContinuation { pending = $0 }
    }
    func cancel() {
        wasCancelled = true
        pending?.resume(returning: false)
        pending = nil
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
