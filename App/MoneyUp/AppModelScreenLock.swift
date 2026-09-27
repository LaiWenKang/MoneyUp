import Foundation
import LocalAuthentication

/// Owner decision, 27 September 2026 (0.7.3): logging from a widget must not
/// wait for Face ID. The auto-lock delay therefore covers the open book with
/// the lock screen instead of closing it. While covered, a widget, control or
/// Shortcut request opens Log alone; every other destination asks for the
/// device owner (Face ID, Touch ID or passcode) first.
///
/// Manual Lock still closes the book and drops the key, and a cold start still
/// opens it through the device-bound key. Those paths never change here.
@MainActor
protocol ScreenAuthenticating: AnyObject {
    func authenticate() async -> Bool
    /// Dismisses a prompt that is still on screen; it then reports failure.
    func cancel()
}

@MainActor
final class DeviceOwnerScreenAuthenticator: ScreenAuthenticating {
    private var context: LAContext?

    func authenticate() async -> Bool {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: AppLocalization.string("lock.authentication_reason")
            )
        } catch {
            return false
        }
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}

extension AppModel {
    /// The auto-lock delay expired. Only an open, ready book is covered. A
    /// restore, erase or other lifecycle change in flight keeps the full lock,
    /// which waits for it to drain and then closes the book as before.
    func autoLock() {
        guard state == .ready, !hasDeferredAuthenticationLock,
              !isLifecycleMutationInProgress, !isBookReplacementInProgress else {
            lock()
            return
        }
        lockScreen()
    }

    func lockScreen() {
        autoLockTask?.cancel()
        autoLockTask = nil
        leftActiveAt = nil
        flushQuickLogDraftImmediately()
        isScreenLocked = true
        // A request that arrived first keeps Log open; otherwise Log-only
        // access ends with the visit that granted it.
        isLogOnlyAccess = requestedQuickLogMode != nil
        requiresAuthenticationPrivacyCover = false
    }

    /// Removes the cover after the device owner authenticates. The key is not
    /// read again because the book never closed.
    @discardableResult
    func unlockScreen() async -> Bool {
        guard isScreenLocked else { return state == .ready }
        guard !isScreenAuthenticationInProgress else { return false }
        isScreenAuthenticationInProgress = true
        let authenticated = await screenAuthenticator.authenticate()
        isScreenAuthenticationInProgress = false
        // Leaving MoneyUp during the prompt cancels it. That exit was not
        // tracked while the prompt was up, so start the visit clock now.
        if !authenticated, !widgetLifecycleRefresh.isSceneActive {
            sceneDidLeaveActive(at: Date())
        }
        guard authenticated, isScreenLocked, state == .ready else {
            return !isScreenLocked && state == .ready
        }
        isScreenLocked = false
        isLogOnlyAccess = false
        return true
    }

    /// The lock screen's button: the cover asks for the device owner; a
    /// closed book opens through the device-bound key as before.
    func unlockFromLockScreen() async {
        if isScreenLocked {
            await unlockScreen()
        } else {
            await start()
        }
    }

    /// A widget, control or Shortcut request while covered opens Log alone.
    /// A prompt already on screen yields to it.
    func beginLogOnlyAccess() {
        guard isScreenLocked, !isLogOnlyAccess else { return }
        isLogOnlyAccess = true
        automaticUnlockIsPending = false
        screenAuthenticator.cancel()
    }

    /// Closing or reopening the book always ends the cover.
    func endScreenLock() {
        guard isScreenLocked || isLogOnlyAccess else { return }
        isScreenLocked = false
        isLogOnlyAccess = false
        screenAuthenticator.cancel()
    }

    /// The single automatic prompt of a covered return. A waiting widget
    /// request goes to Log instead of prompting.
    func unlockScreenAutomaticallyIfNeeded() async -> Bool {
        guard widgetLifecycleRefresh.isSceneActive,
              isScreenLocked,
              !isLogOnlyAccess,
              state == .ready,
              automaticUnlockIsPending,
              requestedQuickLogMode == nil,
              quickActionRouteBroker.pendingAction == nil,
              !isScreenAuthenticationInProgress else { return false }
        automaticUnlockIsPending = false
        return await unlockScreen()
    }
}
