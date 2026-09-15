import Foundation
import MoneyUpCore

struct QuickLogSmartFill {
    let draft: QuickLogDraft
    let messageKeys: [String]

    init(parsed: ParsedNaturalLanguageEntry, current: QuickLogDraft, accounts: [LedgerAccount]) {
        var result = current
        var messages: [String] = []
        var existingContent = current
        existingContent.smartText = ""
        let parsedKind: QuickLogKind = switch parsed.draft.kind {
        case .expense: .expense
        case .income: .income
        case .refund: .refund
        }
        if !existingContent.hasTransactionContent { result.kind = parsedKind }
        if result.kind != parsedKind { messages.append("quick_log.smart_kind_review") }
        if !current.accountWasEdited,
           let id = parsed.draft.accountID,
           accounts.contains(where: { $0.id == id && !$0.isArchived }) {
            if current.amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || current.accountID == id {
                result.accountID = id
                result.accountWasEdited = true
            } else {
                messages.append("quick_log.smart_currency_review")
            }
        }
        let currency = accounts.first { $0.id == result.accountID }?.currency
        let namedAccountCurrency = accounts.first { $0.id == parsed.draft.accountID }?.currency
        let evidence = parsed.currencyEvidence
        let currencyIsCompatible = (evidence.codes.isEmpty && !evidence.hasAmbiguousSymbol
            || evidence.permitsAutomaticFill(in: currency))
            && (namedAccountCurrency == nil || namedAccountCurrency == currency)
        if !currencyIsCompatible { messages.append("quick_log.smart_currency_review") }
        if parsed.needsAmountReview { messages.append("quick_log.smart_amount_review") }
        if parsed.needsDateReview { messages.append("quick_log.smart_date_review") }
        if current.amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           currencyIsCompatible, let amount = parsed.draft.amount {
            if let currency, MonetaryInputPolicy.accepts(amount, currency: currency) {
                result.amountText = editableAmount(amount)
            } else {
                messages.append("quick_log.smart_precision_review")
            }
        }
        if !current.dateWasEdited, let date = parsed.draft.occurredAt {
            result.occurredAt = date
            result.dateWasEdited = true
        }
        if current.payee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let payee = parsed.draft.payee { result.payee = payee }
        if current.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let note = parsed.note { result.note = note }
        if !current.categoryWasEdited, current.splitLines.isEmpty,
           let id = parsed.draft.categoryID,
           accounts.contains(where: {
               $0.id == id && !$0.isArchived
                   && $0.kind == (result.kind == .income ? .income : .expense)
           }) {
            result.categoryID = id
            result.categoryWasEdited = true
        }
        draft = result
        if messages.isEmpty, parsed.draft.isEmpty, parsed.note == nil,
           parsed.draft.accountID == nil, parsed.draft.categoryID == nil {
            messages.append("quick_log.smart_nothing_found")
        }
        messageKeys = messages.isEmpty ? ["quick_log.smart_review"]
            : messages.reduce(into: [String]()) { keys, key in
                if !keys.contains(key) { keys.append(key) }
            }
    }
}

/// A single application policy for the full preview and every field arrow.
/// Manual edits (including an explicitly cleared field), parser values, split
/// work and captured records retain their authority across draft restoration.
enum QuickLogHistoryPreloadFill {
    static let fields: Set<QuickLogSmartField> = [.payee, .amount, .account, .category]

    static func fill(_ suggestion: HistoryPreloadSuggestion, current: QuickLogDraft,
                     accounts: [LedgerAccount], only requested: Set<QuickLogSmartField> = fields) -> QuickLogDraft {
        var result = current
        let kind: CaptureIntelligenceKind = switch current.kind {
        case .expense: .expense
        case .income: .income
        case .refund: .refund
        case .transfer: .transfer
        }
        guard kind == suggestion.kind, current.splitLines.isEmpty,
              current.selectedAllowanceID == nil,
              let account = accounts.first(where: {
                  $0.id == suggestion.fields.accountSuggestion?.ledgerAccountID && !$0.isArchived
                      && $0.systemRole == nil && ($0.kind == .asset || $0.kind == .liability)
                      && $0.currency == suggestion.currency
              }),
              let category = accounts.first(where: {
                  $0.id == suggestion.fields.categorySuggestion?.ledgerAccountID && !$0.isArchived
                      && $0.systemRole == nil && $0.kind == (current.kind == .income ? .income : .expense)
                      && ($0.currency == nil || $0.currency == suggestion.currency)
              }) else { return current }
        let protected = current.smartState.manualFields.union(current.smartState.automaticFields)
        // Partial merchant input can narrow a pattern without granting
        // permission to replace that text. Unrelated patterns cannot apply.
        if let typed = PayeeNormalization.key(current.payee),
           PayeeNormalization.key(suggestion.payee)?.contains(typed) != true { return current }
        if requested.contains(.payee), !protected.contains(.payee), current.payee.isEmpty {
            result.payee = suggestion.payee
            result.smartState.edited(.payee)
        }
        if requested.contains(.account), !protected.contains(.account), !current.accountWasEdited,
           current.amountText.isEmpty, current.sourceCaptureID == nil {
            result.accountID = account.id
            result.accountWasEdited = true
            result.smartState.edited(.account)
        }
        let effectiveAccount = accounts.first { $0.id == result.accountID && !$0.isArchived }
        guard effectiveAccount?.currency == suggestion.currency else { return current }
        if requested.contains(.amount), !protected.contains(.amount), current.amountText.isEmpty,
           let money = suggestion.amount, money.currency == suggestion.currency,
           money.amount > .zero, MonetaryInputPolicy.accepts(money.amount, currency: money.currency),
           effectiveAccount?.id == account.id {
            result.amountText = editableAmount(money.amount)
            result.smartState.edited(.amount)
        }
        if requested.contains(.category), !protected.contains(.category), !current.categoryWasEdited,
           current.sourceCaptureID == nil, effectiveAccount?.id == account.id {
            result.categoryID = category.id
            result.categoryWasEdited = true
            result.smartState.edited(.category)
        }
        return result
    }
}
