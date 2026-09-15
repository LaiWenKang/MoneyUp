import Foundation
import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    func refreshTypedPayeeSuggestion() {
        let normalized = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .transfer, normalized.isEmpty || normalized.count >= 2 else {
            invalidateCaptureSuggestions()
            return
        }
        let draftKind: DraftKind = kind == .income
            ? .income : (kind == .refund ? .refund : .expense)
        refreshCaptureSuggestions(
            for: TransactionDraft(
                kind: draftKind,
                payee: normalized,
                source: .naturalLanguage
            )
        )
    }

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
        historyPreloads = []
        if restoresDefaults, revertedField {
            selectDefaults()
        }
    }

    func clearCaptureSuggestionProvenance() {
        cancelCaptureSuggestionLookup()
        autoAppliedAccountSuggestionID = nil
        autoAppliedCategorySuggestionID = nil
        captureSuggestionResult = nil
        historyPreloads = []
    }

    func clearPerTransactionReviewState() {
        cancelSmartParsing()
        smartState = .init()
        clearRecovery = nil
        smartMessage = nil
        receiptResult = nil
        clearCaptureSuggestionProvenance()
        cancelOnDeviceAssistance()
        pendingDuplicateReview = nil
        receiptAttachmentData = nil
        retainReceiptAttachment = false
        receiptRetentionMessage = nil
        evidencePreparationGeneration &+= 1
        isPreparingEvidence = false
        evidencePreparationTask?.cancel()
        evidencePreparationTask = nil
        evidencePhotoItems = []
        attachmentDrafts = []
        evidenceMessage = nil
        photoItem = nil
        errorMessage = nil
    }

    func refreshCaptureSuggestions(for draft: TransactionDraft) {
        cancelCaptureSuggestionLookup()
        historyPreloads = []
        captureSuggestionResult = nil
        guard model.profile?.intelligenceEnabled == true,
              model.profile?.merchantSuggestionsEnabled != false,
              let currency = selectedAccountCurrency else {
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
        let protected = smartState.manualFields.union(smartState.automaticFields)
        let fixedAccount = accountWasEdited || protected.contains(.account) || !amountText.isEmpty
            || sourceCaptureID != nil ? accountID : nil
        let fixedCategory = categoryWasEdited || protected.contains(.category)
            || sourceCaptureID != nil ? categoryID : nil
        captureSuggestionTask = Task { @MainActor in
            // Coalesce typing without running an indexed lookup per keystroke.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled, !MoneyUpKeyboard.hasMarkedText else { return }
            let result = await model.historyPreloadSuggestions(for: query,
                eligibleCategoryIDs: eligibleCategoryIDs, accountID: fixedAccount, categoryID: fixedCategory)
            guard !Task.isCancelled, generation == captureSuggestionGeneration,
                  logicalBookRevision == model.logicalBookRevision,
                  !model.isBookReplacementInProgress,
                  model.profile?.intelligenceEnabled == true,
                  model.profile?.merchantSuggestionsEnabled != false else { return }
            captureSuggestionResult = result.fields
            historyPreloadBookRevision = logicalBookRevision
            historyPreloads = result.merchants
            captureSuggestionTask = nil
        }
    }

    func cancelCaptureSuggestionLookup() {
        captureSuggestionGeneration &+= 1
        captureSuggestionTask?.cancel()
        captureSuggestionTask = nil
    }

    @ViewBuilder
    var historyPreloadRows: some View {
        if !historyPreloads.isEmpty, splitLines.isEmpty, selectedAllowanceID == nil,
           model.profile?.intelligenceEnabled == true,
           model.profile?.merchantSuggestionsEnabled != false {
            VStack(alignment: .leading, spacing: 12) {
                Text("quick_log.preload_title").font(.caption.weight(.semibold))
                ForEach(historyPreloads) { suggestion in
                    let available = Set(QuickLogHistoryPreloadFill.fields.filter {
                        preloadDraft(suggestion, fields: [$0]) != draftSnapshot
                    })
                    HistoryPreloadCard(suggestion: suggestion,
                        accountName: sourceAccounts.first {
                            $0.id == suggestion.fields.accountSuggestion?.ledgerAccountID
                        }?.name ?? "",
                        categoryName: suggestion.fields.categorySuggestion.map {
                            model.categoryPathName(for: $0.ledgerAccountID)
                        } ?? "", available: available,
                        canApplyAll: preloadDraft(suggestion, fields: QuickLogHistoryPreloadFill.fields) != draftSnapshot
                    ) { fields in applyHistoryPreload(suggestion, fields: fields) }
                }
                Text("quick_log.preload_context_detail").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func preloadDraft(_ suggestion: HistoryPreloadSuggestion,
                              fields: Set<QuickLogSmartField>) -> QuickLogDraft {
        QuickLogHistoryPreloadFill.fill(suggestion, current: draftSnapshot,
            accounts: sourceAccounts + categories, only: fields)
    }

    func applyHistoryPreload(_ suggestion: HistoryPreloadSuggestion,
                             fields: Set<QuickLogSmartField>) {
        guard !isSaving, !isScanning, !isCheckingDuplicates, !isClearingDraft,
              model.state == .ready, !model.isBookReplacementInProgress,
              model.profile?.intelligenceEnabled == true,
              model.profile?.merchantSuggestionsEnabled != false,
              historyPreloadBookRevision == model.logicalBookRevision,
              historyPreloads.contains(suggestion) else { return }
        let baseline = draftSnapshot
        let updated = preloadDraft(suggestion, fields: fields)
        guard updated != baseline else { return }
        cancelSmartParsing()
        cancelOnDeviceAssistance()
        if updated.payee != baseline.payee { receiptProtectedFields.insert(\.payee) }
        if updated.amountText != baseline.amountText { receiptProtectedFields.insert(\.amountText) }
        if updated.accountID != baseline.accountID { receiptProtectedFields.insert(\.accountID) }
        if updated.categoryID != baseline.categoryID { receiptProtectedFields.insert(\.categoryID) }
        applyDraft(updated)
        if !dismissAfterSave { model.updateQuickLogDraft(updated) }
        refreshTypedPayeeSuggestion()
    }

    @ViewBuilder
    func captureSuggestions(_ result: CaptureSuggestionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("quick_log.suggestions_from_book", systemImage: "lightbulb.max")
                .font(.subheadline.weight(.semibold))
            if !accountWasEdited,
               !smartState.manualFields.contains(.account), !smartState.automaticFields.contains(.account),
               let suggestion = result.accountSuggestion,
               let account = sourceAccounts.first(where: {
                   $0.id == suggestion.ledgerAccountID
               }) {
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
                    smartState.edited(.account)
                    receiptProtectedFields.insert(\.accountID)
                    accountID = account.id
                    accountWasEdited = true
                    autoAppliedAccountSuggestionID = nil
                    persistUserDraftChange { $0.accountID = account.id }
                }
            }
            if splitLines.isEmpty, !categoryWasEdited,
               !smartState.manualFields.contains(.category), !smartState.automaticFields.contains(.category),
               let suggestion = result.categorySuggestion,
               let category = categories.first(where: { $0.id == suggestion.ledgerAccountID }) {
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
                    smartState.edited(.category)
                    receiptProtectedFields.insert(\.categoryID)
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
                Text(accountCurrencyLabel(account))
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


struct HistoryPreloadCard: View {
    let suggestion: HistoryPreloadSuggestion
    let accountName: String
    let categoryName: String
    let available: Set<QuickLogSmartField>
    let canApplyAll: Bool
    let apply: (Set<QuickLogSmartField>) -> Void
    @State var expanded = false

    private var amountLabel: String {
        guard let money = suggestion.amount else {
            return AppLocalization.string("quick_log.preload_amount_uncertain")
        }
        return money.currency.value + " " + MoneyAmountPrivacy.protected(editableAmount(money.amount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.payee).font(.body.weight(.medium))
                    Text(amountLabel).font(.subheadline.monospacedDigit())
                    Text(accountName + " · " + categoryName).font(.caption)
                }
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { apply(QuickLogHistoryPreloadFill.fields) } label: {
                    Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!canApplyAll)
                .accessibilityLabel("quick_log.preload_fill_untouched")
                .accessibilityHint("quick_log.preload_preserve_detail")
            }
            DisclosureGroup("quick_log.preload_choose_fields", isExpanded: $expanded) {
                field("transaction.title_or_merchant", value: suggestion.payee, key: .payee)
                field("quick_log.amount", value: amountLabel, key: .amount)
                field("transaction.account", value: accountName, key: .account)
                field("transaction.category", value: categoryName, key: .category)
                Text("quick_log.preload_preserve_detail").font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func field(_ title: LocalizedStringKey, value: String,
                       key: QuickLogSmartField) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption)
                Text(value).font(.subheadline)
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { apply([key]) } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .disabled(!available.contains(key))
            .accessibilityLabel(Text(title) + Text(": ") + Text(value))
            .accessibilityHint("quick_log.preload_preserve_detail")
        }
    }
}
