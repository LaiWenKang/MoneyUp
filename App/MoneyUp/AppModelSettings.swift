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

    func updatePreferredAccount(_ id: UUID?) async throws {
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
        requestedQuickLogMode = nil
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
            let databaseURL: URL
            if let databaseURLForErase {
                databaseURL = databaseURLForErase
            } else {
                databaseURL = try Self.databaseURL()
            }
            try await Self.completePendingDataErase(
                databaseURL: databaseURL,
                deleteDatabaseKey: deleteDatabaseKey,
                lockedCaptureStore: lockedCaptureStore,
                clearEraseIntent: dataEraseIntent.clear
            )
            pendingLockedCaptureCount = 0
            if restartAfterErase {
                finishExclusiveDataLifecycleMutation()
                await start()
            } else {
                state = .onboarding
                finishExclusiveDataLifecycleMutation()
            }
        } catch {
            lockAfterStart = false
            clearDecodedState()
            state = .failed(safeUserMessage(for: error, context: .save))
            isWorking = false
            finishExclusiveDataLifecycleMutation()
        }
    }
}
