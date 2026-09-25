import Foundation
import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    var quickLogHistoryPreloadChrome: some View {
        quickLogFormChrome
            .onChange(of: model.accounts) { _, _ in
                if !draftSnapshot.hasUserEdits { selectDefaults() }
                refreshTypedPayeeSuggestion()
            }
            .onChange(of: accountID) { _, _ in refreshTypedPayeeSuggestion() }
            .onChange(of: categoryID) { _, _ in refreshTypedPayeeSuggestion() }
            .onChange(of: occurredAt) { _, _ in refreshTypedPayeeSuggestion() }
            .onChange(of: model.profile?.merchantSuggestionsEnabled) { _, _ in refreshTypedPayeeSuggestion() }
            .onChange(of: model.profile?.intelligenceEnabled) { _, _ in refreshTypedPayeeSuggestion() }
    }

    func refreshTypedPayeeSuggestion() {
        let normalized = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .transfer, normalized.isEmpty || normalized.utf8.count >= 2 else {
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
        guard model.profile?.intelligenceEnabled == true,
              model.profile?.merchantSuggestionsEnabled != false,
              let currency = selectedAccountCurrency else {
            historyPreloads = []
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
        let eligibleAccountIDs = Set(sourceAccounts.map(\.id))
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
                eligibleCategoryIDs: eligibleCategoryIDs, accountID: fixedAccount, categoryID: fixedCategory,
                eligibleAccountIDs: eligibleAccountIDs)
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
            // One tap fills every untouched field; a long press picks fields.
            // The explanation lives in the accessibility hint, not on screen.
            VStack(alignment: .leading, spacing: 8) {
                Label("quick_log.preload_title", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(historyPreloads) { suggestion in
                            let available = Set(QuickLogHistoryPreloadFill.fields.filter {
                                preloadDraft(suggestion, fields: [$0]) != draftSnapshot
                            })
                            HistoryPreloadChip(
                                suggestion: suggestion,
                                categoryName: suggestion.fields.categorySuggestion.map {
                                    model.categoryPathName(for: $0.ledgerAccountID)
                                } ?? "",
                                available: available,
                                canApplyAll: preloadDraft(suggestion, fields: QuickLogHistoryPreloadFill.fields) != draftSnapshot
                            ) { fields in applyHistoryPreload(suggestion, fields: fields) }
                            .disabled(captureSuggestionTask != nil)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityHint("quick_log.preload_context_detail")
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
        guard captureSuggestionTask == nil,
              !isSaving, !isScanning, !isCheckingDuplicates, !isClearingDraft,
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
        let wasShowingOptionalDetails = isShowingOptionalDetails
        applyDraft(updated)
        isShowingOptionalDetails = wasShowingOptionalDetails
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("quick_log.suggestions_book_scope")
        .disabled(captureSuggestionTask != nil)
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


/// A recent entry's amount as every other surface writes money: the display
/// formatter's minor units ("SGD 18.60", never the editable "18.6") and an
/// explicit code, because the chip's currency may differ from the draft's.
@MainActor
func historyPreloadAmountLabel(_ amount: Money?) -> String {
    guard let amount else {
        return AppLocalization.string("quick_log.preload_amount_uncertain")
    }
    return formattedMoneyWithCurrencyCode(amount)
}

/// A recent entry as a capsule: payee, amount and category at a glance.
struct HistoryPreloadChip: View {
    @Environment(AppModel.self) private var model
    let suggestion: HistoryPreloadSuggestion
    let categoryName: String
    let available: Set<QuickLogSmartField>
    let canApplyAll: Bool
    let apply: (Set<QuickLogSmartField>) -> Void

    private var amountLabel: String { historyPreloadAmountLabel(suggestion.amount) }

    /// The category's own glyph and tint, as History and Today draw it; the
    /// entry kind's sign when no category was learned.
    private var glyph: (symbol: String, tint: Color) {
        if let categoryID = suggestion.fields.categorySuggestion?.ledgerAccountID {
            return (MoneyUpCategorySymbol.symbol(for: categoryID, accountsByID: model.accountsByID),
                    MoneyUpCategorySymbol.tint(for: categoryID))
        }
        switch suggestion.kind {
        case .income: return (MoneyUpEntryGlyph.income, Color.moneyUpPositive)
        case .refund: return (MoneyUpEntryGlyph.refund, Color.moneyUpPositive)
        case .transfer, .foreignCurrencyTransfer: return (MoneyUpEntryGlyph.transfer, Color.accentColor)
        case .expense: return (MoneyUpEntryGlyph.expense, Color.accentColor)
        }
    }

    var body: some View {
        Button { apply(QuickLogHistoryPreloadFill.fields) } label: {
            HStack(spacing: 8) {
                MoneyUpCategoryBadge(systemImage: glyph.symbol, tint: glyph.tint, size: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.payee)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(amountLabel).monospacedDigit()
                        if !categoryName.isEmpty {
                            Text(verbatim: "·")
                            Text(categoryName).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.moneyUpSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.18), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canApplyAll)
        .contextMenu {
            Button("transaction.title_or_merchant") { apply([.payee]) }.disabled(!available.contains(.payee))
            Button("quick_log.amount") { apply([.amount]) }.disabled(!available.contains(.amount))
            Button("transaction.account") { apply([.account]) }.disabled(!available.contains(.account))
            Button("transaction.category") { apply([.category]) }.disabled(!available.contains(.category))
        }
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityHint("quick_log.preload_preserve_detail")
    }

    /// VoiceOver hears "amounts hidden" rather than the visual mask, and the
    /// category the chip shows.
    private var accessibilityText: String {
        var parts = [suggestion.payee]
        if let money = suggestion.amount {
            parts.append(accessibleFormattedMoney(money))
        } else {
            parts.append(AppLocalization.string("quick_log.preload_amount_uncertain"))
        }
        if !categoryName.isEmpty { parts.append(categoryName) }
        return parts.joined(separator: ", ")
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

    private var amountLabel: String { historyPreloadAmountLabel(suggestion.amount) }

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
