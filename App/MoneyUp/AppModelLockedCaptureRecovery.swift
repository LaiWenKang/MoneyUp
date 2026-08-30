import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func promotePendingLockedCapture() async throws {
        try beginLockedCapturePromotion()
        defer { endLockedCapturePromotion() }
        let generation = storeGeneration
        let currentStore = try requireStore()
        try await promoteLockedCaptureIfPossible(
            to: currentStore,
            generation: generation
        )
    }

    func beginLockedCapturePromotion() throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        lockedCapturePromotionInProgress = true
    }

    func endLockedCapturePromotion() {
        lockedCapturePromotionInProgress = false
        applyDeferredLockIfPossible()
    }

    static let lockedCaptureSourceSystem = "MoneyUp Locked Capture"

    static func lockedCaptureFingerprint(_ id: UUID) -> String {
        "locked-capture:\(id.uuidString.lowercased())"
    }

    func promoteLockedCaptureIfPossible(
        to store: EncryptedRecordStore,
        generation: Int,
        requestLogRoute: Bool = true
    ) async throws {
        var captures = try await lockedCaptureStore.all()
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = captures.count

        if let sourceID = quickLogDraft?.sourceCaptureID {
            let remainingCaptureCount = try await lockedCaptureStore.remove(id: sourceID)
            guard ownsStoreGeneration(generation) else { return }
            pendingLockedCaptureCount = remainingCaptureCount
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }
        guard quickLogDraft == nil else {
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }

        while let replay = captures.first,
              try await store.containsJournalEntry(
                sourceFingerprint: Self.lockedCaptureFingerprint(replay.id)
              ) {
            pendingLockedCaptureCount = try await lockedCaptureStore.remove(
                id: replay.id
            )
            captures.removeFirst()
            guard ownsStoreGeneration(generation) else { return }
        }
        guard let capture = captures.first else {
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }

        let kind: QuickLogKind
        let mode: QuickLogLaunchMode
        switch capture.kind {
        case .income:
            kind = .income
            mode = .income
        case .transfer:
            kind = .transfer
            mode = .transfer
        case .expense:
            kind = .expense
            mode = .expense
        case .refund:
            kind = .refund
            mode = .refund
        }
        let draft = QuickLogDraft(
            kind: kind,
            amountText: capture.amountText,
            destinationAmountText: "",
            accountID: nil,
            destinationAccountID: nil,
            categoryID: nil,
            occurredAt: capture.occurredAt,
            dateWasEdited: true,
            payee: capture.payee,
            note: capture.note,
            smartText: "",
            sourceCaptureID: capture.id
        )
        try await store.upsert(
            draft,
            id: QuickLogDraft.primaryRecordID,
            in: .quickLogDrafts
        )
        await lifecycleHooks.checkpoint(.afterCaptureDraftPersisted)
        guard ownsStoreGeneration(generation) else { return }
        quickLogDraft = draft
        let remainingCaptureCount = try await lockedCaptureStore.remove(id: capture.id)
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = remainingCaptureCount
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        if requestLogRoute { requestedQuickLogMode = mode }
    }

    func recordRecoveryIssue(_ issue: String) {
        guard !recoveryIssues.contains(issue) else { return }
        recoveryIssues.append(issue)
    }

    func recordLockedCaptureStoreIssue(
        _ error: LockedCaptureStoreError
    ) {
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        let suffix = error.isDefinitivelyUnrecoverable
            ? "unrecoverable"
            : "unavailable"
        recordRecoveryIssue("locked_captures/\(suffix)")
    }

    /// Classifies each account hierarchy once. A root-to-leaf walk for every
    /// account is quadratic for a deep but otherwise valid hierarchy and can
    /// make opening an authenticated archive appear to hang. Invalidity is
    /// inherited by descendants, so missing parents, kind mismatches, and
    /// every member/descendant of a cycle are quarantined together.
    nonisolated static func invalidAccountHierarchyIDs(
        in accounts: [LedgerAccount],
        observesCancellation: Bool = true
    ) throws -> Set<UUID> {
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        // 1 = active path, 2 = resolves to a valid root, 3 = invalid.
        var resolutionByID: [UUID: UInt8] = [:]
        resolutionByID.reserveCapacity(accountByID.count)
        var inspectedCount = 0

        for account in accounts where resolutionByID[account.id] == nil {
            var path: [UUID] = []
            var currentID: UUID? = account.id
            var resolvesToValidRoot = true

            while let id = currentID {
                if observesCancellation,
                   inspectedCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                inspectedCount += 1

                switch resolutionByID[id] {
                case 1:
                    resolvesToValidRoot = false
                    currentID = nil
                    continue
                case 2:
                    resolvesToValidRoot = true
                    currentID = nil
                    continue
                case 3:
                    resolvesToValidRoot = false
                    currentID = nil
                    continue
                default:
                    break
                }

                guard let current = accountByID[id] else {
                    resolvesToValidRoot = false
                    break
                }
                resolutionByID[id] = 1
                path.append(id)

                guard let parentID = current.parentID else {
                    resolvesToValidRoot = true
                    break
                }
                guard let parent = accountByID[parentID],
                      parent.kind == current.kind else {
                    resolvesToValidRoot = false
                    break
                }
                currentID = parentID
            }

            let resolution: UInt8 = resolvesToValidRoot ? 2 : 3
            for id in path {
                resolutionByID[id] = resolution
            }
        }

        return Set(resolutionByID.compactMap { item in
            item.value == 3 ? item.key : nil
        })
    }

    /// Rejects logical identity ambiguity without deleting forensic/recovery
    /// evidence from the encrypted store.
}
