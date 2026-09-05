import MoneyUpCore
import Foundation

extension AppModel {
    var displayPreferences: MoneyUpDisplayPreferences {
        pendingDisplayPreferences ?? profile?.displayPreferences ?? .init()
    }

    func changeDisplayPreferences(
        _ mutation: (inout MoneyUpDisplayPreferences) -> Void
    ) {
        guard profile != nil, state == .ready else { return }
        var candidate = displayPreferences
        mutation(&candidate)
        pendingDisplayPreferences = candidate
        displayPreferenceRequest &+= 1
        let request = displayPreferenceRequest
        let generation = storeGeneration
        displayPreferenceFailure = nil
        displayPreferenceWriteTask = Task { @MainActor in
            do {
                try await saveDisplayPreferences(
                    candidate, request: request, generation: generation
                )
            } catch {
                guard request == displayPreferenceRequest,
                      generation == storeGeneration else { return }
                pendingDisplayPreferences = nil
                displayPreferenceFailure = error
            }
        }
    }

    func saveDisplayPreferences(
        _ candidate: MoneyUpDisplayPreferences,
        request: UInt64,
        generation: Int
    ) async throws {
        await profileMutationSerializer.acquire()
        do {
            guard request == displayPreferenceRequest,
                  generation == storeGeneration,
                  var updated = profile else {
                await profileMutationSerializer.release()
                return
            }
            updated.displayPreferences = candidate
            updated.displayPreferences.hiddenGuidanceCategoryIDs.formIntersection(Set(budgetNodes.map(\.id)))
            try await persist(updatedProfile: updated)
            if request == displayPreferenceRequest, generation == storeGeneration {
                pendingDisplayPreferences = nil
            }
            await profileMutationSerializer.release()
        } catch {
            await profileMutationSerializer.release()
            throw error
        }
    }
}
