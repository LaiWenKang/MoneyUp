import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func reviewPendingLockedCapturesForBackup() async throws {
        try beginLockedCapturePromotion()
        defer { endLockedCapturePromotion() }
        let generation = storeGeneration
        try await promoteLockedCaptureIfPossible(
            to: requireStore(), generation: generation, requestLogRoute: false
        )
        guard ownsStoreGeneration(generation), state == .ready else { throw AppModelError.locked }
        // Promotion preserves an existing draft. Route to that draft's type so
        // reviewing the inbox cannot replace an unfinished income or transfer.
        guard let draft = quickLogDraft else { return }
        let mode: QuickLogLaunchMode = switch draft.kind {
        case .expense: .expense
        case .income: .income
        case .transfer: .transfer
        case .refund: .refund
        }
        requestedQuickLogMode = mode
    }

    /// Deletes every waiting capture from the device inbox and the book copy.
    /// Nothing was ever posted, so there is no journal effect. The current
    /// draft is untouched even if it originated in a capture.
    func discardPendingLockedCaptures() async throws {
        try beginLockedCapturePromotion()
        defer { endLockedCapturePromotion() }
        let generation = storeGeneration
        let captureStore = try requireStore()
        let captures = try await pendingLockedCaptures(in: captureStore)
        for capture in captures {
            guard ownsStoreGeneration(generation) else { return }
            pendingLockedCaptureCount = try await removePendingLockedCapture(
                id: capture.id, in: captureStore
            )
        }
        guard ownsStoreGeneration(generation) else { return }
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
    }

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
        var captures = try await pendingLockedCaptures(in: store)
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = captures.count

        if let sourceID = quickLogDraft?.sourceCaptureID {
            let remainingCaptureCount = try await removePendingLockedCapture(id: sourceID, in: store)
            guard ownsStoreGeneration(generation) else { return }
            pendingLockedCaptureCount = remainingCaptureCount
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }
        // A draft record exists as soon as Log has been opened once. Only a
        // draft with real user input may keep a capture waiting; a blank
        // routing draft is replaced so the capture opens straight in Log.
        if let existing = quickLogDraft, existing.hasUserEdits {
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }

        while let replay = captures.first,
              try await store.containsJournalEntry(
                sourceFingerprint: Self.lockedCaptureFingerprint(replay.id)
              ) {
            pendingLockedCaptureCount = try await removePendingLockedCapture(
                id: replay.id, in: store
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
        let draft = lockedCaptureDraft(capture, kind: kind)
        try await store.upsert(
            draft,
            id: QuickLogDraft.primaryRecordID,
            in: .quickLogDrafts
        )
        await lifecycleHooks.checkpoint(.afterCaptureDraftPersisted)
        guard ownsStoreGeneration(generation) else { return }
        publishModelQuickLogDraft(draft)
        let remainingCaptureCount = try await removePendingLockedCapture(id: capture.id, in: store)
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = remainingCaptureCount
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        if requestLogRoute { requestedQuickLogMode = mode }
    }

    /// A capture made from an opted-in locked favourite regains that
    /// favourite's account and category, matched inside the open book.
    func lockedCaptureDraft(_ capture: LockedCapture, kind: QuickLogKind) -> QuickLogDraft {
        let routing = lockedFavouriteRouting(for: capture)
        return QuickLogDraft(
            kind: kind,
            amountText: capture.amountText,
            destinationAmountText: "",
            accountID: routing?.accountID,
            destinationAccountID: nil,
            categoryID: routing?.categoryID,
            occurredAt: capture.occurredAt,
            dateWasEdited: true,
            payee: capture.payee,
            note: capture.note,
            smartText: "",
            sourceCaptureID: capture.id,
            accountWasEdited: routing?.accountID != nil,
            categoryWasEdited: routing?.categoryID != nil
        )
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
