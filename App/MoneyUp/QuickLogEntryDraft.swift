import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

extension QuickLogEntryView {
    var draftSnapshot: QuickLogDraft {
        QuickLogDraft(
            kind: kind,
            amountText: amountText,
            destinationAmountText: destinationAmountText,
            accountID: accountID,
            destinationAccountID: destinationAccountID,
            categoryID: categoryID,
            occurredAt: occurredAt,
            dateWasEdited: dateWasEdited,
            payee: payee,
            note: note,
            smartText: smartText,
            splitLines: splitLines,
            sourceCaptureID: sourceCaptureID
        )
    }

    /// Writes direct control edits to the model in the same setter that updates
    /// SwiftUI state. The app-level background callback can therefore flush the
    /// final keystroke even if SwiftUI has not delivered `onChange` yet.
    func trackedBinding<Value>(
        _ binding: Binding<Value>,
        _ keyPath: WritableKeyPath<QuickLogDraft, Value>,
        refreshesOccurrenceDate: Bool = false,
        onUserEdit: @escaping () -> Void = {}
    ) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if refreshesOccurrenceDate {
                    refreshUntouchedOccurrenceDate(persist: false)
                }
                binding.wrappedValue = newValue
                onUserEdit()
                persistUserDraftChange { snapshot in
                    snapshot[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func refreshUntouchedOccurrenceDate(persist: Bool = true) {
        guard hasRestoredDraft,
              !dismissAfterSave,
              QuickLogOccurrencePolicy.shouldRefresh(
                  hasTransactionContent: draftSnapshot.hasTransactionContent,
                  dateWasEdited: dateWasEdited,
                  sourceCaptureID: sourceCaptureID
              ) else { return }
        occurredAt = model.currentDateForUserAction()
        if persist {
            model.updateQuickLogDraft(draftSnapshot)
        }
    }

    func persistUserDraftChange(
        _ update: (inout QuickLogDraft) -> Void
    ) {
        guard hasRestoredDraft, !dismissAfterSave else { return }
        var snapshot = draftSnapshot
        update(&snapshot)
        model.updateQuickLogDraft(snapshot)
    }

    func restoreDraftIfAvailable() {
        guard !dismissAfterSave, let draft = model.quickLogDraft else { return }
        if hasRestoredDraft, draft == draftSnapshot { return }
        if hasRestoredDraft {
            clearPerTransactionReviewState()
        }
        // Restore first. A conflicting widget request is resolved explicitly
        // below instead of silently reinterpreting or discarding this content.
        applyDraft(draft)
    }

    func applyDraft(_ draft: QuickLogDraft) {
        kind = draft.kind
        amountText = draft.amountText
        destinationAmountText = draft.destinationAmountText
        accountID = draft.accountID
        destinationAccountID = draft.destinationAccountID
        categoryID = draft.categoryID
        accountWasEdited = draft.accountID != nil
        categoryWasEdited = draft.categoryID != nil
        occurredAt = draft.hasTransactionContent
            ? draft.occurredAt : model.currentDateForUserAction()
        dateWasEdited = draft.dateWasEdited
        payee = draft.payee
        note = draft.note
        smartText = draft.smartText
        splitLines = draft.splitLines
        sourceCaptureID = draft.sourceCaptureID
        isShowingOptionalDetails = draft.dateWasEdited
            || !draft.payee.isEmpty
            || !draft.note.isEmpty
    }

    func handleRequestedLaunch() {
        guard !dismissAfterSave,
              !isSaving,
              !isScanning,
              requestSequence != 0,
              requestSequence != handledRequestSequence,
              let launchMode else { return }
        handledRequestSequence = requestSequence
        if sourceCaptureID != nil {
            // Unlock promotion itself routes to Log. It is the same durable
            // draft, not a request to discard it and start another entry.
            onRequestHandled(launchMode)
            focusedField = .amount
            return
        }
        if draftSnapshot.hasTransactionContent {
            // Every external action means “start or focus an entry.” Protect
            // even same-kind drafts: Smart Entry and receipt parsing can
            // otherwise overwrite an unfinished expense in place.
            pendingLaunchMode = launchMode
            isConfirmingDraftSwitch = true
            return
        }
        performLaunch(launchMode)
        onRequestHandled(launchMode)
    }

    func discardDraftAndLaunch(_ launchMode: QuickLogLaunchMode) {
        cancelReceiptProcessing()
        accountWasEdited = false
        categoryWasEdited = false
        amountText = ""
        destinationAmountText = ""
        occurredAt = model.currentDateForUserAction()
        dateWasEdited = false
        payee = ""
        note = ""
        smartText = ""
        smartMessage = nil
        receiptResult = nil
        captureSuggestionResult = nil
        autoAppliedAccountSuggestionID = nil
        autoAppliedCategorySuggestionID = nil
        pendingDuplicateReview = nil
        splitLines = []
        sourceCaptureID = nil
        receiptAttachmentData = nil
        retainReceiptAttachment = false
        receiptRetentionMessage = nil
        errorMessage = nil
        performLaunch(launchMode)
        selectDefaults()
        model.updateQuickLogDraft(draftSnapshot)
    }

    func performLaunch(_ launchMode: QuickLogLaunchMode) {
        refreshUntouchedOccurrenceDate()
        kind = launchMode.kind

        switch launchMode {
        case .smartEntry:
            isHandlingFocusedLaunch = true
            focusedField = .smartEntry
        case .scanReceipt:
            isHandlingFocusedLaunch = true
            dismissKeyboard()
            Task { @MainActor in
                await Task.yield()
                isPresentingReceiptPicker = true
            }
        case .expense, .income, .transfer, .refund:
            isHandlingFocusedLaunch = false
            focusedField = .amount
        }
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
    }

    /// `dd/mm` and `mm/dd` cannot be told apart from the digits alone, so the
    /// reader follows whatever order this locale writes dates in.
    static var localePrefersDayFirst: Bool {
        let format = DateFormatter.dateFormat(
            fromTemplate: "yMd",
            options: 0,
            locale: .current
        ) ?? "d/M/y"
        guard let day = format.firstIndex(of: "d"),
              let month = format.firstIndex(of: "M") else { return true }
        return day < month
    }

    func applyTypedPhrase() {
        receiptResult = nil
        invalidateCaptureSuggestions()
        pendingDuplicateReview = nil
        let draft = NaturalLanguageEntryParser.draft(
            from: smartText,
            accounts: model.accounts,
            now: model.currentDateForUserAction(),
            calendar: model.reportingCalendar,
            prefersDayFirst: Self.localePrefersDayFirst
        )
        if apply(draft) {
            smartText = ""
            if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        }
    }
}
