import Foundation

extension AppModel {
    /// An activation can spend one authentication attempt. Native authentication
    /// itself makes the scene inactive; that interval must not arm another one.
    func prepareAutomaticUnlockAfterInactivity() {
        guard !isStarting else { return }
        automaticUnlockIsPending = true
    }

    /// Explicit Lock stays locked for the remainder of this foreground visit.
    /// A later visit still requires the device owner's presence.
    func lockManually() {
        automaticUnlockIsPending = false
        lock()
    }

    @discardableResult
    func unlockAutomaticallyIfNeeded() async -> Bool {
        guard widgetLifecycleRefresh.isSceneActive,
              state == .locked,
              automaticUnlockIsPending,
              !isWorking,
              !isLifecycleMutationInProgress,
              !quickActionRouteBroker.isAuthoritativeBoundaryActive,
              !canPresentLockedQuickCapture else { return false }
        // Claim before suspending. Explicit retry and cold startup consume the
        // same opportunity in beginStartupWork, so callback ordering is harmless.
        automaticUnlockIsPending = false
        return await start()
    }
}
