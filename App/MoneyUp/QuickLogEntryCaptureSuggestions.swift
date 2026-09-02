import Foundation
import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    func invalidateCaptureSuggestions(
        preservingAccount: Bool = false,
        preservingCategory: Bool = false,
        restoresDefaults: Bool = true
    ) {
        cancelCaptureSuggestionLookup()
        var revertedField = false
        if !preservingAccount,
           let autoAppliedAccountSuggestionID,
           accountID == autoAppliedAccountSuggestionID {
            accountID = nil
            accountWasEdited = false
            revertedField = true
        }
        if !preservingCategory,
           let autoAppliedCategorySuggestionID,
           categoryID == autoAppliedCategorySuggestionID {
            categoryID = nil
            categoryWasEdited = false
            revertedField = true
        }
        autoAppliedAccountSuggestionID = nil
        autoAppliedCategorySuggestionID = nil
        captureSuggestionResult = nil
        if restoresDefaults, revertedField {
            selectDefaults()
        }
    }

    func clearCaptureSuggestionProvenance() {
        cancelCaptureSuggestionLookup()
        autoAppliedAccountSuggestionID = nil
        autoAppliedCategorySuggestionID = nil
        captureSuggestionResult = nil
    }

    func clearPerTransactionReviewState() {
        smartMessage = nil
        receiptResult = nil
        clearCaptureSuggestionProvenance()
        cancelOnDeviceAssistance()
        pendingDuplicateReview = nil
        receiptAttachmentData = nil
        retainReceiptAttachment = false
        receiptRetentionMessage = nil
        photoItem = nil
        errorMessage = nil
    }

    func refreshCaptureSuggestions(for draft: TransactionDraft) {
        cancelCaptureSuggestionLookup()
        guard let currency = selectedAccountCurrency else {
            captureSuggestionResult = nil
            return
        }
        let suggestionKind: CaptureIntelligenceKind
        switch draft.kind {
        case .expense: suggestionKind = .expense
        case .income: suggestionKind = .income
        case .refund: suggestionKind = .refund
        }
        let query = CaptureSuggestionQuery(
            kind: suggestionKind,
            payee: draft.payee,
            currency: currency,
            occurredAt: draft.occurredAt ?? occurredAt
        )
        let generation = captureSuggestionGeneration
        let logicalBookRevision = model.logicalBookRevision
        let eligibleCategoryIDs = Set(categories.map(\.id))
        captureSuggestionTask = Task { @MainActor in
            let result = await model.indexedCaptureSuggestion(
                for: query,
                eligibleCategoryIDs: eligibleCategoryIDs
            )
            guard !Task.isCancelled,
                  generation == captureSuggestionGeneration,
                  logicalBookRevision == model.logicalBookRevision,
                  !model.isBookReplacementInProgress else { return }
            captureSuggestionResult = result
            applyAccountSuggestion(result.accountSuggestion, draft: draft)
            applyCategorySuggestion(result.categorySuggestion, draft: draft)
            captureSuggestionTask = nil
        }
    }

    func cancelCaptureSuggestionLookup() {
        captureSuggestionGeneration &+= 1
        captureSuggestionTask?.cancel()
        captureSuggestionTask = nil
    }

    private func applyAccountSuggestion(
        _ suggestion: CaptureFieldSuggestion?,
        draft: TransactionDraft
    ) {
        guard let suggestion,
              QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                  confidence: suggestion.confidence,
                  fieldWasEdited: accountWasEdited,
                  parserSuppliedValue: draft.accountID != nil,
                  hasFixedDefault: validPreferred(
                      model.profile?.preferredAccountID,
                      in: model.userAccounts
                  ) != nil,
                  usedPayeeHistory: suggestion.evidence.usedPayeeHistory
              ),
              model.userAccounts.contains(where: {
                  $0.id == suggestion.ledgerAccountID
              }) else { return }
        invalidateOnDeviceAccountForDeterministicChange()
        accountID = suggestion.ledgerAccountID
        autoAppliedAccountSuggestionID = suggestion.ledgerAccountID
    }

    private func applyCategorySuggestion(
        _ suggestion: CaptureFieldSuggestion?,
        draft: TransactionDraft
    ) {
        guard splitLines.isEmpty,
              let suggestion,
              QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                  confidence: suggestion.confidence,
                  fieldWasEdited: categoryWasEdited,
                  parserSuppliedValue: draft.categoryID != nil,
                  hasFixedDefault: preferredCategoryIDForCurrentKind != nil,
                  usedPayeeHistory: suggestion.evidence.usedPayeeHistory
              ),
              categories.contains(where: {
                  $0.id == suggestion.ledgerAccountID
              }) else { return }
        invalidateOnDeviceCategoryForDeterministicChange()
        categoryID = suggestion.ledgerAccountID
        autoAppliedCategorySuggestionID = suggestion.ledgerAccountID
    }

    private var preferredCategoryIDForCurrentKind: UUID? {
        switch kind {
        case .income:
            validPreferred(
                model.profile?.preferredIncomeCategoryID,
                in: model.incomeCategories
            )
        case .expense, .refund:
            validPreferred(
                model.profile?.preferredExpenseCategoryID,
                in: model.expenseCategories
            )
        case .transfer:
            nil
        }
    }

    @ViewBuilder
    func captureSuggestions(_ result: CaptureSuggestionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("quick_log.suggestions_from_book", systemImage: "lightbulb.max")
                .font(.subheadline.weight(.semibold))
            if let suggestion = result.accountSuggestion,
               let account = model.accountsByID[suggestion.ledgerAccountID] {
                captureSuggestionRow(
                    title: AppLocalization.string("quick_log.suggested_account"),
                    account: account,
                    suggestion: suggestion,
                    isApplied: accountID == account.id,
                    useAccessibilityLabel: String(
                        format: AppLocalization.string(
                            "quick_log.use_account_accessibility_format"
                        ),
                        account.name
                    )
                ) {
                    invalidateOnDeviceAccountForDeterministicChange()
                    accountID = account.id
                    accountWasEdited = true
                    autoAppliedAccountSuggestionID = nil
                    persistUserDraftChange { $0.accountID = account.id }
                }
            }
            if splitLines.isEmpty,
               let suggestion = result.categorySuggestion,
               let category = model.accountsByID[suggestion.ledgerAccountID] {
                captureSuggestionRow(
                    title: AppLocalization.string("quick_log.suggested_category"),
                    account: category,
                    suggestion: suggestion,
                    isApplied: categoryID == category.id,
                    useAccessibilityLabel: String(
                        format: AppLocalization.string(
                            "quick_log.use_category_accessibility_format"
                        ),
                        category.name
                    )
                ) {
                    invalidateOnDeviceCategoryForDeterministicChange()
                    categoryID = category.id
                    categoryWasEdited = true
                    autoAppliedCategorySuggestionID = nil
                    persistUserDraftChange { $0.categoryID = category.id }
                }
            }
            Text("quick_log.suggestions_book_scope")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func captureSuggestionRow(
        title: String,
        account: LedgerAccount,
        suggestion: CaptureFieldSuggestion,
        isApplied: Bool,
        useAccessibilityLabel: String,
        apply: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.name)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                if isApplied {
                    Label("quick_log.suggestion_applied", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button("quick_log.use_suggestion", action: apply)
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            Text(useAccessibilityLabel)
                        )
                }
            }
            Text(
                "\(captureConfidenceText(suggestion.confidence)) · "
                    + captureEvidenceText(suggestion.evidence)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    func captureConfidenceText(_ confidence: CaptureConfidence) -> String {
        switch confidence {
        case .low: AppLocalization.string("quick_log.confidence_low")
        case .medium: AppLocalization.string("quick_log.confidence_medium")
        case .high: AppLocalization.string("quick_log.confidence_high")
        }
    }

    private func captureEvidenceText(_ evidence: CaptureSuggestionEvidence) -> String {
        let format = evidence.usedPayeeHistory
            ? AppLocalization.string("quick_log.suggestion_payee_evidence_format")
            : AppLocalization.string("quick_log.suggestion_kind_evidence_format")
        let count = String(
            format: format,
            evidence.supportingEntryCount,
            evidence.eligibleEntryCount
        )
        let date = evidence.mostRecentUse.formattedForReporting(
            .dateTime.year().month(.abbreviated).day(),
            calendar: model.reportingCalendar
        )
        return String(
            format: AppLocalization.string("quick_log.suggestion_last_used_format"),
            count,
            date
        )
    }
}
