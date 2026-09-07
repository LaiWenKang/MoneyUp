import Foundation
import MoneyUpCore

/// These actions prepare a new transaction. They never correct the source
/// journal or copy receipt evidence, recurrence ownership, or replay identity.
enum TransactionPreparationAction: Sendable {
    case repeatEntry
    case refund
}

enum TransactionPreparationPolicy {
    static func draft(
        from entry: JournalEntry, action: TransactionPreparationAction,
        accounts: [LedgerAccount], now: Date
    ) -> QuickLogDraft? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let values = EditableEntryValues(entry: entry, accounts: accounts),
              values.amount > .zero else { return nil }
        let referencedIDs = Set(entry.postings.map(\.accountID))
        let referenced = accounts.filter { referencedIDs.contains($0.id) }
        guard referenced.allSatisfy({ !$0.isArchived && $0.accountType != .restrictedAllowance }),
              Set(referenced.map(\.id)) == referencedIDs else { return nil }
        if action == .refund, values.kind != .expense { return nil }
        return QuickLogDraft(
            kind: action == .refund ? .refund : values.kind,
            amountText: editableAmount(values.amount),
            destinationAmountText: values.destinationAmount.map { editableAmount($0) } ?? "",
            accountID: values.accountID, destinationAccountID: values.destinationAccountID,
            categoryID: values.categoryID, occurredAt: now, dateWasEdited: false,
            payee: entry.payee ?? "", note: entry.note ?? "", smartText: "",
            splitLines: values.splitLines.map {
                QuickLogSplitDraftLine(categoryID: $0.categoryID, amountText: $0.amountText, memo: $0.memo)
            }
        )
    }
}

extension AppModel {
    /// The caller supplies exactly the draft it showed before asking to replace
    /// it. A changed draft or source invalidates consent instead of losing work.
    func prepareTransaction(
        from original: JournalEntry, action: TransactionPreparationAction,
        replacing expectedDraft: QuickLogDraft?
    ) async throws {
        guard state == .ready, quickLogDraft == expectedDraft else {
            throw AppModelError.transactionInProgress
        }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        defer { endLifecycleMutation() }
        let draftStore = try requireStore()
        await finishPendingQuickLogDraftWrite()
        try await flushQuickLogDraftForBackup(to: draftStore)
        let current = try await draftStore.fetch(
            JournalEntry.self, id: original.id.uuidString, from: .journalEntries
        )
        guard current == original, !isProtectedJournalEntry(original),
              quickLogDraft == expectedDraft,
              let draft = TransactionPreparationPolicy.draft(
                  from: original, action: action, accounts: accounts,
                  now: currentDateForUserAction()
              ) else { throw AppModelError.missingRecord }
        try Task.checkCancellation()
        try await draftStore.upsert(draft, id: QuickLogDraft.primaryRecordID, in: .quickLogDrafts)
        quickLogDraft = draft
        quickLogPreparationRevision &+= 1
    }
}
