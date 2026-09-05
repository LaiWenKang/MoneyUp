import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func updateAutoLockDelay(_ seconds: TimeInterval) async throws {
        guard UserProfile.allowedAutoLockDelays.contains(seconds) else {
            throw AppModelError.invalidBook
        }
        try await mutateProfile { $0.autoLockDelay = seconds }
    }

    func updateLockedQuickCapture(_ enabled: Bool) async throws {
        try await mutateProfile { $0.allowLockedQuickCapture = enabled }
        UserDefaults.standard.set(enabled, forKey: Self.lockedQuickCapturePreferenceKey)
    }

    func updateBudgetStatusWidget(_ enabled: Bool) async throws {
        try await mutateProfile { $0.showsBudgetStatusWidget = enabled }
        // `profile`'s observer publishes the redacted snapshot. Reloading is
        // explicit here as well so disabling takes effect immediately.
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    func updateIntelligenceEnabled(_ enabled: Bool) async throws {
        let wasEnabled = profile?.intelligenceEnabled == true
        if !enabled { intelligenceService.cancelPendingWork() }
        do {
            try await mutateProfile { $0.intelligenceEnabled = enabled }
        } catch {
            if wasEnabled { refreshIntelligence() }
            throw error
        }
        if enabled {
            refreshIntelligence()
        } else {
            intelligenceService.cancelPendingWork()
        }
    }

    func updateFoundationModelAssistance(_ enabled: Bool) async throws {
        try await mutateProfile {
            $0.foundationModelAssistanceEnabled = enabled
        }
    }

    func updateReportingTimeZone(_ identifier: String) async throws {
        guard let zone = TimeZone(identifier: identifier) else {
            throw AppModelError.invalidBook
        }
        try await mutateProfile { $0.reportingTimeZoneIdentifier = zone.identifier }
    }

    func updatePreferredAccount(_ id: UUID?) async throws {
        if let id {
            guard let account = accountsByID[id],
                  !account.isArchived,
                  account.systemRole == nil,
                  account.accountType != .restrictedAllowance,
                  account.kind == .asset || account.kind == .liability else {
                throw AppModelError.invalidAllowance
            }
        }
        try await mutateProfile { $0.preferredAccountID = id }
    }

    func updatePreferredExpenseCategory(_ id: UUID?) async throws {
        try await mutateProfile { $0.preferredExpenseCategoryID = id }
    }

    func updatePreferredIncomeCategory(_ id: UUID?) async throws {
        try await mutateProfile { $0.preferredIncomeCategoryID = id }
    }

    func mutateProfile(
        _ mutation: (inout UserProfile) throws -> Void
    ) async throws {
        await profileMutationSerializer.acquire()
        do {
            guard var updated = profile else { throw AppModelError.missingRecord }
            try mutation(&updated)
            try await persist(updatedProfile: updated)
            await profileMutationSerializer.release()
        } catch {
            await profileMutationSerializer.release()
            throw error
        }
    }

    func persist(updatedProfile: UserProfile) async throws {
        guard UserProfile.allowedAutoLockDelays.contains(
            updatedProfile.autoLockDelay
        ), TimeZone(
            identifier: updatedProfile.reportingTimeZoneIdentifier
        ) != nil else {
            throw AppModelError.invalidBook
        }
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        let generation = storeGeneration
        let profileStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeProfileWrite)
        try await profileStore.upsert(
            updatedProfile,
            id: UserProfile.primaryRecordID,
            in: .profile
        )
        guard isCurrentStoreGeneration(generation) else { return }
        profile = updatedProfile
    }

    func eraseAllDataAndRestart() async {
        let pendingCommit = quickLogCommit.flatMap {
            $0.generation == storeGeneration ? $0.task : nil
        }
        guard !isWorking,
              !isLifecycleMutationInProgress,
              standaloneJournalMutationsInProgress == 0,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty,
              !lockedCapturePromotionInProgress,
              !lockedCaptureWriteInProgress,
              !manualJournalMutationIsActive || pendingCommit != nil else {
            return
        }
        guard let quickActionBoundaryEpoch =
                beginEraseQuickActionBoundary() else { return }
        var quickActionRecoveryWasValidated = false
        defer {
            finishQuickActionBoundary(
                quickActionBoundaryEpoch,
                validatedRecovery: quickActionRecoveryWasValidated
            )
        }
        isWorking = true
        goalMutationBarrierClosed = true
        isLifecycleMutationInProgress = true
        // Persist intent before the first destructive step. From this point a
        // process kill or power loss makes startup resume the erase instead of
        // silently reopening the old book.
        do {
            try dataEraseIntent.markPending()
        } catch {
            state = .failed(safeUserMessage(for: error, context: .save))
            finishExclusiveDataLifecycleMutation()
            return
        }
        await waitForGoalMutationDrain()
        invalidateInFlightJournalProjection()
        state = .launching
        lockAfterStart = false
        let pendingDraftWrite = quickLogDraftWriteTask
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        quickLogCommit = nil
        if let pendingClose = storeCloseTask {
            await pendingClose.value
            storeCloseTask = nil
        }
        let storeToClose = store
        store = nil
        storeGeneration &+= 1
        disableBudgetWidgetSnapshot()
        clearDecodedState()
        await pendingDraftWrite?.value
        if let pendingCommit {
            _ = try? await pendingCommit.value
        }
        await storeToClose?.close()

        do {
            let databaseURL = try databaseURLForErase ?? Self.databaseURL()
            try await Self.completePendingDataErase(
                databaseURL: databaseURL,
                deleteDatabaseKey: deleteDatabaseKey,
                lockedCaptureStore: lockedCaptureStore,
                removeKeyCliffRecoveryArtifacts: { try KeyCliffRecoveryTransaction.removeAll(for: databaseURL) },
                clearEraseIntent: dataEraseIntent.clear
            )
            finishSuccessfulEraseRecoveryState()
            quickActionRecoveryWasValidated =
                await finishSuccessfulEraseAndRestartIfNeeded()
        } catch {
            lockAfterStart = false
            clearDecodedState()
            state = .failed(safeUserMessage(for: error, context: .save))
            isWorking = false
            finishExclusiveDataLifecycleMutation()
        }
    }

    private func beginEraseQuickActionBoundary() -> UInt64? {
        do {
            return try beginAuthoritativeQuickActionBoundary()
        } catch {
            state = .failed(safeUserMessage(for: error, context: .save))
            return nil
        }
    }

    private func finishSuccessfulEraseRecoveryState() {
        pendingLockedCaptureCount = 0
        startupFailureKind = nil
    }

    private func finishSuccessfulEraseAndRestartIfNeeded() async -> Bool {
        guard restartAfterErase else {
            state = .onboarding
            finishExclusiveDataLifecycleMutation()
            return true
        }
        finishExclusiveDataLifecycleMutation()
        // Startup's validation result is authoritative even when a deferred
        // background lock deliberately publishes `.locked` afterward. The
        // outer erase boundary must still reopen ingress after that safe,
        // fully validated replacement startup.
        return await start()
    }
}
