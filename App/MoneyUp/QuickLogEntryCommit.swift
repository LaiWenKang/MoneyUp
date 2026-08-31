import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

private enum QuickLogSaveOutcome {
    case skipped
    case saved(UUID?)
}

extension QuickLogEntryView {
    func commitSave() async {
        guard !isSaving, canSave else { return }
        guard let amount, let accountID else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let retainedReceipt = retainReceiptAttachment ? receiptAttachmentData : nil
            let outcome = try await saveEntry(
                amount: amount,
                accountID: accountID,
                receiptData: retainedReceipt
            )
            guard case let .saved(savedEntryID) = outcome else { return }

            completeSuccessfulSave(entryID: savedEntryID)
            if dismissAfterSave {
                dismiss()
            }
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func saveEntry(
        amount: Decimal,
        accountID: UUID,
        receiptData: Data?
    ) async throws -> QuickLogSaveOutcome {
        if !splitLines.isEmpty, kind != .transfer {
            return .saved(try await saveSplit(
                kind: kind,
                amount: amount,
                accountID: accountID,
                receiptData: receiptData
            ))
        }

        switch kind {
        case .expense:
            guard let categoryID else { return .skipped }
            return .saved(try await model.logExpense(
                amount: amount,
                accountID: accountID,
                categoryID: categoryID,
                occurredAt: occurredAt,
                payee: payee,
                note: note,
                receiptData: receiptData
            ))
        case .income:
            guard let categoryID else { return .skipped }
            return .saved(try await model.logIncome(
                amount: amount,
                accountID: accountID,
                categoryID: categoryID,
                occurredAt: occurredAt,
                payee: payee,
                note: note,
                receiptData: receiptData
            ))
        case .refund:
            guard let categoryID else { return .skipped }
            return .saved(try await model.logRefund(
                amount: amount,
                accountID: accountID,
                categoryID: categoryID,
                occurredAt: occurredAt,
                payee: payee,
                note: note,
                receiptData: receiptData
            ))
        case .transfer:
            guard let destinationAccountID else { return .skipped }
            return .saved(try await model.logTransfer(
                amount: amount,
                destinationAmount: isForeignCurrencyTransfer
                    ? destinationAmount
                    : nil,
                sourceAccountID: accountID,
                destinationAccountID: destinationAccountID,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            ))
        }
    }

    func saveSplit(
        kind: QuickLogKind,
        amount: Decimal,
        accountID: UUID,
        receiptData: Data?
    ) async throws -> UUID? {
        guard let currency = selectedAccountCurrency else {
            throw AppModelError.accountHasNoCurrency
        }
        let lines = try transactionSplitLines(currency: currency)
        let total = try Money(amount, currency: currency)
        try TransactionSplitCalculator.validate(total: total, lines: lines)
        return try await model.logSplitTransaction(
            kind: kind,
            amount: amount,
            accountID: accountID,
            lines: lines,
            occurredAt: occurredAt,
            payee: payee,
            note: note,
            receiptData: receiptData
        )
    }

    func transactionSplitLines(
        currency: CurrencyCode
    ) throws -> [TransactionSplitLine] {
        try splitLines.map { line -> TransactionSplitLine in
            guard let categoryID = line.categoryID,
                  let splitAmount = decimalAmount(from: line.amountText) else {
                throw AppModelError.missingRecord
            }
            return TransactionSplitLine(
                id: line.id,
                categoryAccountID: categoryID,
                amount: try Money(splitAmount, currency: currency),
                memo: line.memo
            )
        }
    }

    /// Clears only fields that belong to the transaction just saved. Account,
    /// category, transaction kind, and transfer destination remain selected so
    /// the next routine entry takes only an amount and a tap on Save.
    func completeSuccessfulSave(entryID: UUID?) {
        cancelReceiptProcessing()
        cancelCaptureSuggestionLookup()
        if let nextCapture = model.quickLogDraft,
           nextCapture.sourceCaptureID != nil,
           !dismissAfterSave {
            clearPerTransactionReviewState()
            applyDraft(nextCapture)
            selectDefaults()
        } else {
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
            photoItem = nil
            errorMessage = nil
            isShowingOptionalDetails = false
            if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        }
        successFeedback += 1
        focusedField = isActive ? .amount : nil

        guard !dismissAfterSave, let entryID else { return }
        updateSavedEntry(entryID)
        if isVoiceOverEnabled {
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(AppLocalization.string("quick_log.saved")). \(AppLocalization.string("action.undo"))"
            )
        }

        Task {
            try? await Task.sleep(for: .seconds(6))
            guard lastSavedEntryID == entryID else { return }
            // VoiceOver users dismiss the persistent correction affordance
            // explicitly, so it cannot vanish before they navigate to Undo.
            guard !isVoiceOverEnabled else { return }
            updateSavedEntry(nil)
        }
    }

    func undo(entryID: UUID) async {
        guard lastSavedEntryID == entryID else { return }
        isUndoing = true
        errorMessage = nil
        defer { isUndoing = false }

        do {
            try await model.deleteEntry(id: entryID)
            updateSavedEntry(nil)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    func updateSavedEntry(_ entryID: UUID?) {
        if QuickLogMotionPolicy.animatesSavedFeedback(
            reduceMotion: accessibilityReduceMotion
        ) {
            withAnimation(.snappy(duration: 0.22)) {
                lastSavedEntryID = entryID
            }
        } else {
            lastSavedEntryID = entryID
        }
    }

    /// Invalidates every late receipt callback before clearing UI state. The
    /// sanitizer's shared serial actor owns the no-overlap boundary even after
    /// this view releases its task handle.
    func cancelReceiptProcessing() {
        receiptScanGeneration &+= 1
        receiptScanTask?.cancel()
        receiptScanTask = nil
        receiptScanBaseline = nil
        isScanning = false
        photoItem = nil
    }

    func clearSplitFocus(for lineID: UUID? = nil) {
        guard let focusedLineID = focusedField?.splitLineID,
              lineID == nil || lineID == focusedLineID else { return }
        focusedField = nil
    }

    /// Decimal pads have no return key. Every Quick Log text field, including
    /// stable split-line identities, participates in this one focus boundary.
    /// Leaving Log remains a pure UI action: no transaction is saved and the
    /// unfinished draft is neither cleared nor reinterpreted as completed.
    func dismissKeyboard() {
        focusedField = nil
    }

    /// A tab change is a navigation action only. Persist the exact current
    /// draft, resign focus, then let the parent select the requested tab.
    func navigate(to destination: QuickLogNavigationDestination) {
        dismissKeyboard()
        if !dismissAfterSave {
            model.updateQuickLogDraft(draftSnapshot)
        }
        onNavigate(destination)
    }
}
