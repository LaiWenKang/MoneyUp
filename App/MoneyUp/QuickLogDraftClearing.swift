import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI

extension QuickLogDraft {
    /// Retain routing choices for the next entry; clear transaction content,
    /// edits, split identities and the current capture's replay identity.
    func cleared(at date: Date) -> QuickLogDraft {
        var cleared = QuickLogDraft(
            kind: kind, amountText: "", destinationAmountText: "",
            accountID: accountID, destinationAccountID: destinationAccountID,
            categoryID: categoryID, occurredAt: date, dateWasEdited: false,
            payee: "", note: "", smartText: ""
        )
        cleared.batch = batch
        return cleared
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
        var cleared = expected.cleared(at: currentDateForUserAction())
        cleared.batch?.revision &+= 1
        cleared.clearRecovery = try QuickLogClearRecovery(draft: expected)
        try await draftStore.upsert(cleared, id: QuickLogDraft.primaryRecordID, in: .quickLogDrafts)
        quickLogDraft = cleared
        quickLogPreparationRevision &+= 1
    }

    func restoreClearedQuickLogDraft(replacing expected: QuickLogDraft) async throws {
        guard state == .ready, quickLogDraft == expected, !expected.hasUserEdits,
              let recovery = expected.clearRecovery else { throw AppModelError.transactionInProgress }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        defer { endLifecycleMutation() }
        let draftStore = try requireStore()
        await finishPendingQuickLogDraftWrite()
        var restored = try recovery.restoredDraft()
        restored.batch = expected.batch
        restored.batch?.revision &+= 1
        try Task.checkCancellation()
        try await draftStore.upsert(restored, id: QuickLogDraft.primaryRecordID, in: .quickLogDrafts)
        quickLogDraft = restored
        quickLogPreparationRevision &+= 1
    }
}

struct QuickLogClearedEvidence {
    let recovery: QuickLogClearRecovery
    let attachments: [ReceiptAttachmentDraft]
    let receiptData: Data?
    let receiptResult: ReceiptParseResult?
    let retainReceipt: Bool
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
        cancelSmartParsing()
        cancelReceiptProcessing()
        cancelCaptureSuggestionLookup()
        cancelOnDeviceAssistance()
        evidencePreparationTask?.cancel()
        do {
            let recovery = try QuickLogClearRecovery(draft: expected)
            let evidence = QuickLogClearedEvidence(recovery: recovery, attachments: attachmentDrafts,
                receiptData: receiptAttachmentData, receiptResult: receiptResult, retainReceipt: retainReceiptAttachment)
            var cleared = expected.cleared(at: model.currentDateForUserAction())
            cleared.clearRecovery = recovery
            if dismissAfterSave {
                clearPerTransactionReviewState()
                applyDraft(cleared)
            } else {
                try await model.clearQuickLogDraft(replacing: expected)
                clearPerTransactionReviewState()
                if let stored = model.quickLogDraft { applyDraft(stored) }
            }
            clearedEvidence = evidence
            isPresentingReceiptPicker = false
            isPresentingEvidencePhotoPicker = false
            isPresentingEvidencePDFPicker = false
            isPreparingEvidence = false
            focusedField = isActive ? .amount : nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    func restoreClearedDraft() async {
        guard !isSaving, !isClearingDraft, !draftSnapshot.hasUserEdits, let clearRecovery else { return }
        isClearingDraft = true
        defer { isClearingDraft = false }
        cancelSmartParsing()
        do {
            if dismissAfterSave { applyDraft(try clearRecovery.restoredDraft()) }
            else {
                try await model.restoreClearedQuickLogDraft(replacing: draftSnapshot)
                if let restored = model.quickLogDraft { applyDraft(restored) }
            }
            if let evidence = clearedEvidence, evidence.recovery == clearRecovery {
                attachmentDrafts = evidence.attachments
                receiptAttachmentData = evidence.receiptData
                receiptResult = evidence.receiptResult
                retainReceiptAttachment = evidence.retainReceipt
            }
            clearedEvidence = nil
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    var clearRecoveryBanner: some View {
        HStack {
            Text("quick_log.entry_cleared")
            Spacer()
            Button("quick_log.restore_entry") { Task { await restoreClearedDraft() } }
                .disabled(draftSnapshot.hasUserEdits || isSaving || isClearingDraft)
                .accessibilityIdentifier("quick-log-restore-cleared")
        }
        .padding(12)
        .background(.regularMaterial)
    }
}
