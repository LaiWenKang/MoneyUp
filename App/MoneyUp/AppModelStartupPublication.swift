import Foundation
import MoneyUpPersistence

extension AppModel {
    func queueRestoreCompletionForReadyHierarchy(_ completion: String) {
        guard !completion.isEmpty else { return }
        pendingRestoreCompletionAnnouncement = completion
    }

    func clearRestoreCompletionForReadyHierarchy() {
        pendingRestoreCompletionAnnouncement = nil
    }

    func takeRestoreCompletionForReadyHierarchy() -> String? {
        guard state == .ready else { return nil }
        defer { pendingRestoreCompletionAnnouncement = nil }
        return pendingRestoreCompletionAnnouncement
    }

    /// Performs only checks that are safe while a key-cliff manifest remains
    /// pending. It does not promote the capture inbox, publish ready/onboarding,
    /// refresh intelligence, or expose a widget projection.
    func validateLoadedStartupBook(
        in openedStore: EncryptedRecordStore
    ) async throws -> Bool {
        guard profile != nil else {
            // A profile is the root of a valid book. Treat onboarding as a
            // genuinely empty-store state only; otherwise an unlisted or newly
            // added collection could be silently overlaid by setup.
            let hasBookData = try await Self.hasPersistedBookData(
                in: openedStore
            )
            guard !hasBookData else { throw AppModelError.invalidBook }
            return false
        }
        try validateLoadedBook()
        return true
    }

    /// Publishes only a validated startup book. Ordinary startup preserves an
    /// unexpected capture failure; the post-marker wrapper below converts that
    /// now-nonrollbackable case into a redacted retry signal.
    func publishValidatedStartupBook(
        in openedStore: EncryptedRecordStore,
        hasProfile: Bool
    ) async throws {
        guard hasProfile else {
            disableBudgetWidgetSnapshot()
            state = .onboarding
            finishUnlockToFirstUsefulContentMeasurement(outcome: .cancelled)
            return
        }
        if let profile {
            UserDefaults.standard.set(
                profile.allowLockedQuickCapture,
                forKey: Self.lockedQuickCapturePreferenceKey
            )
        }
        do {
            try await promoteLockedCaptureIfPossible(
                to: openedStore,
                generation: storeGeneration
            )
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
        }
        state = .ready
        if !isBookReplacementInProgress {
            refreshIntelligence()
        }
    }

    /// Once the marker is removed, capture promotion cannot roll the installed
    /// book back. Keep that book usable and retain a stable, privacy-safe retry
    /// signal for any unexpected inbox failure.
    func publishValidatedStartupBookAfterIrreversibleRecovery(
        in openedStore: EncryptedRecordStore,
        hasProfile: Bool
    ) async {
        do {
            try await publishValidatedStartupBook(
                in: openedStore,
                hasProfile: hasProfile
            )
        } catch {
            recordRecoveryIssue("locked_captures/promotion-unavailable")
            state = .ready
            if !isBookReplacementInProgress {
                refreshIntelligence()
            }
        }
    }

    func finishLoadedStartup(
        in openedStore: EncryptedRecordStore
    ) async throws {
        let hasProfile = try await validateLoadedStartupBook(in: openedStore)
        try await publishValidatedStartupBook(
            in: openedStore,
            hasProfile: hasProfile
        )
    }
}
