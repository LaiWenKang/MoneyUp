import Foundation
import MoneyUpCore

enum QuickLogUnderstandingFill {
    static func fill(_ interpretation: SmartEntryInterpretation, current: QuickLogDraft, accounts: [LedgerAccount], now: Date) -> QuickLogDraft {
        guard interpretation.shape != .multiple, !interpretation.issues.contains(.inputLimit) else {
            var blocked = current
            blocked.smartState.hasPreview = true
            blocked.smartState.issues = interpretation.issues
            return blocked
        }
        var baseline = refreshingAutomaticFields(current, now: now)
        if interpretation.shape == .transfer, !baseline.smartState.manualFields.contains(.kind) {
            baseline.kind = .transfer
        }
        var result = interpretation.shape == .transfer ? baseline
            : QuickLogSmartFill(parsed: interpretation.parsed, current: baseline, accounts: accounts).draft
        if current.smartState.manualFields.contains(.kind) { result.kind = current.kind }
        var issues = interpretation.issues
        if interpretation.shape == .transfer {
            fillTransfer(interpretation, draft: &result, accounts: accounts, issues: &issues)
        } else if interpretation.shape == .split, !current.smartState.manualFields.contains(.splits) {
            fillSplits(interpretation, draft: &result, accounts: accounts, issues: &issues)
        }
        validateMoney(interpretation, draft: result, accounts: accounts, issues: &issues)
        if !result.dateWasEdited, let date = interpretation.parsed.draft.occurredAt {
            result.occurredAt = date
            result.dateWasEdited = true
        }
        if result.note.isEmpty, let note = interpretation.parsed.note { result.note = note }
        result.smartState.referenceDate = current.smartState.referenceDate ?? now
        result.smartState.hasPreview = true
        result.smartState.issues = Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
        for field in current.smartState.manualFields { result.smartState.edited(field) }
        markAutomaticChanges(from: baseline, to: &result)
        if current.kind != result.kind, !current.smartState.manualFields.contains(.kind) {
            result.smartState.automaticFields.insert(.kind)
        }
        return result
    }

    private static func refreshingAutomaticFields(_ current: QuickLogDraft, now: Date) -> QuickLogDraft {
        var result = current
        for field in current.smartState.automaticFields {
            switch field {
            case .amount: result.amountText = ""
            case .receivedAmount: result.destinationAmountText = ""
            case .payee: result.payee = ""
            case .note: result.note = ""
            case .date: result.dateWasEdited = false; result.occurredAt = now
            case .account: result.accountWasEdited = false
            case .category: result.categoryWasEdited = false
            case .splits: result.splitLines = []
            case .kind, .destination: break
            }
        }
        return result
    }

    private static func fillTransfer(_ input: SmartEntryInterpretation, draft: inout QuickLogDraft,
                                     accounts: [LedgerAccount], issues: inout [SmartEntryIssue]) {
        guard draft.kind == .transfer else { issues.append(.kind); return }
        if !draft.accountWasEdited, let id = input.sourceAccountID { draft.accountID = id }
        if !draft.smartState.manualFields.contains(.destination), let id = input.destinationAccountID { draft.destinationAccountID = id }
        let source = accounts.first { $0.id == draft.accountID }
        let target = accounts.first { $0.id == draft.destinationAccountID }
        if draft.amountText.isEmpty, let value = input.parsed.draft.amount, let currency = source?.currency,
           input.parsed.currencyEvidence.permitsAutomaticFill(in: currency), MonetaryInputPolicy.accepts(value, currency: currency) {
            draft.amountText = editableAmount(value)
        }
        if draft.destinationAmountText.isEmpty, let value = input.destinationAmount, let currency = target?.currency,
           input.destinationCurrencyEvidence.permitsAutomaticFill(in: currency), MonetaryInputPolicy.accepts(value, currency: currency) {
            draft.destinationAmountText = editableAmount(value)
        }
        if source?.currency != target?.currency, draft.destinationAmountText.isEmpty { issues.append(.receivedAmount) }
        if !draft.splitLines.isEmpty { issues.append(.split) }
    }

    private static func fillSplits(_ input: SmartEntryInterpretation, draft: inout QuickLogDraft,
                                   accounts: [LedgerAccount], issues: inout [SmartEntryIssue]) {
        guard !input.splits.isEmpty, !input.issues.contains(.split), draft.kind != .transfer,
              let currency = accounts.first(where: { $0.id == draft.accountID })?.currency,
              input.parsed.currencyEvidence.permitsAutomaticFill(in: currency),
              input.splits.allSatisfy({ MonetaryInputPolicy.accepts($0.amount, currency: currency) }) else {
            issues.append(.split); return
        }
        if decimalAmount(from: draft.amountText) != input.parsed.draft.amount { issues.append(.split) }
        draft.splitLines = input.splits.map { QuickLogSplitDraftLine(categoryID: $0.categoryID, amountText: editableAmount($0.amount)) }
    }

    private static func validateMoney(_ input: SmartEntryInterpretation, draft: QuickLogDraft,
                                      accounts: [LedgerAccount], issues: inout [SmartEntryIssue]) {
        let currency = accounts.first { $0.id == draft.accountID }?.currency
        if !draft.smartState.manualFields.contains(.amount) {
            if !input.parsed.currencyEvidence.permitsAutomaticFill(in: currency) { issues.append(.currency) }
            if draft.amountText.isEmpty { issues.append(.amount) }
        }
        if input.shape == .single {
            if let named = input.parsed.draft.accountID,
               accounts.first(where: { $0.id == named })?.currency != currency { issues.append(.currency) }
            let expected: QuickLogKind = switch input.parsed.draft.kind {
            case .expense: .expense
            case .income: .income
            case .refund: .refund
            }
            if expected != draft.kind { issues.append(.kind) }
        }
    }

    private static func markAutomaticChanges(from baseline: QuickLogDraft, to result: inout QuickLogDraft) {
        let changes: [(QuickLogSmartField, Bool)] = [
            (.kind, baseline.kind != result.kind), (.amount, baseline.amountText != result.amountText),
            (.receivedAmount, baseline.destinationAmountText != result.destinationAmountText),
            (.account, baseline.accountID != result.accountID), (.destination, baseline.destinationAccountID != result.destinationAccountID),
            (.category, baseline.categoryID != result.categoryID), (.date, baseline.occurredAt != result.occurredAt),
            (.payee, baseline.payee != result.payee), (.note, baseline.note != result.note),
            (.splits, baseline.splitLines != result.splitLines)
        ]
        for (field, changed) in changes where changed && !result.smartState.manualFields.contains(field) {
            result.smartState.automaticFields.insert(field)
        }
    }
}
