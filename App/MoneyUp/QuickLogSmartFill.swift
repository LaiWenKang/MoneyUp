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
