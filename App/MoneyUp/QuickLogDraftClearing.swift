import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI

extension QuickLogDraft {
    /// Retain routing choices for the next entry; clear transaction content,
    /// edits, split identities and the current capture's replay identity.
    func cleared(at date: Date) -> QuickLogDraft {
        QuickLogDraft(
            kind: kind, amountText: "", destinationAmountText: "",
            accountID: accountID, destinationAccountID: destinationAccountID,
            categoryID: categoryID, occurredAt: date, dateWasEdited: false,
            payee: "", note: "", smartText: ""
        )
    }
}

extension AppModel {
    /// Confirmed clearing shares the draft-replacement boundary used by Repeat
    /// and Refund. Publish only after storage succeeds; stale consent fails.
    func clearQuickLogDraft(replacing expected: QuickLogDraft) async throws {
        guard state == .ready, quickLogDraft == expected else {
            throw AppModelError.transactionInProgress
        }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        defer { endLifecycleMutation() }
        let draftStore = try requireStore()
        await finishPendingQuickLogDraftWrite()
        guard quickLogDraft == expected else { throw AppModelError.transactionInProgress }
        try Task.checkCancellation()
        // A promotion interrupted between its durable copy and inbox cleanup
        // must not bring this explicitly discarded capture back on next unlock.
        if let sourceID = expected.sourceCaptureID {
            pendingLockedCaptureCount = try await removePendingLockedCapture(id: sourceID, in: draftStore)
        }
        let cleared = expected.cleared(at: currentDateForUserAction())
        try await draftStore.upsert(cleared, id: QuickLogDraft.primaryRecordID, in: .quickLogDrafts)
        quickLogDraft = cleared
        quickLogPreparationRevision &+= 1
    }
}

extension QuickLogEntryView {
    var hasClearableDraft: Bool {
        draftSnapshot.hasUserEdits || !attachmentDrafts.isEmpty
            || receiptAttachmentData != nil || isScanning || isPreparingEvidence
    }

    func requestDraftClear() {
        guard hasClearableDraft, !isSaving, !isUndoing,
              !isCheckingDuplicates, !isClearingDraft else { return }
        dismissKeyboard()
        pendingDraftClear = draftSnapshot
    }

    func clearConfirmedDraft(_ expected: QuickLogDraft) async {
        guard draftSnapshot == expected, !isSaving, !isUndoing,
              !isCheckingDuplicates, !isClearingDraft else { return }
        isClearingDraft = true
        defer { isClearingDraft = false }
        cancelReceiptProcessing()
        cancelCaptureSuggestionLookup()
        cancelOnDeviceAssistance()
        evidencePreparationTask?.cancel()
        do {
            if dismissAfterSave {
                applyDraft(expected.cleared(at: model.currentDateForUserAction()))
            } else {
                try await model.clearQuickLogDraft(replacing: expected)
                if let cleared = model.quickLogDraft { applyDraft(cleared) }
            }
            clearPerTransactionReviewState()
            isPresentingReceiptPicker = false
            isPresentingEvidencePhotoPicker = false
            isPresentingEvidencePDFPicker = false
            isPreparingEvidence = false
            focusedField = isActive ? .amount : nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
