import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension AppModel {
    func beginQuickLogBatch(_ prepared: QuickLogDraft, replacing expected: QuickLogDraft) async throws {
        guard QuickLogBatchPreparation.canReplaceTextOnlyDraft(expected), let batch = prepared.batch else {
            throw AppModelError.transactionInProgress
        }
        try batch.validate()
        for item in batch.items { _ = try item.draft() }
        try await replaceQuickLogBatchDraft(prepared, replacing: expected)
    }

    func selectQuickLogBatchItem(_ itemID: UUID, replacing expected: QuickLogDraft) async throws {
        guard let batch = expected.batch else { throw AppModelError.missingRecord }
        let next = try batch.selecting(itemID, current: expected)
        try await replaceQuickLogBatchDraft(validatedBatchDraft(next), replacing: expected)
    }

    func removeQuickLogBatchItem(replacing expected: QuickLogDraft) async throws {
        guard let batch = expected.batch else { throw AppModelError.missingRecord }
        var replacement = try batch.removingCurrent(expected)
        if replacement == nil {
            var blank = expected.cleared(at: currentDateForUserAction())
            blank.batch = nil
            replacement = blank
        }
        guard let replacement else { throw AppModelError.invalidBook }
        try await replaceQuickLogBatchDraft(replacement, replacing: expected)
    }

    func batchReferencesLedgerItem(_ id: UUID) throws -> Bool {
        guard let current = quickLogDraft, let batch = current.batch else { return false }
        let drafts = try batch.items.map { item in
            item.id == batch.selectedID ? current : try item.draft()
        }
        return drafts.contains { draft in
            [draft.accountID, draft.destinationAccountID, draft.categoryID].contains(id)
                || draft.splitLines.contains { $0.categoryID == id }
        }
    }

    func validatedBatchDraft(_ original: QuickLogDraft) -> QuickLogDraft {
        var draft = original
        let active = accounts.filter { !$0.isArchived && $0.systemRole == nil }
        if let id = draft.accountID, !active.contains(where: { $0.id == id && ($0.kind == .asset || $0.kind == .liability) }) {
            draft.accountID = nil
            draft.accountWasEdited = false
            draft.smartState.issues.append(.account)
        }
        if let id = draft.destinationAccountID, !active.contains(where: { $0.id == id && ($0.kind == .asset || $0.kind == .liability) }) {
            draft.destinationAccountID = nil
            draft.smartState.issues.append(.destination)
        }
        let kind: LedgerAccountKind = draft.kind == .income ? .income : .expense
        if let id = draft.categoryID, !active.contains(where: { $0.id == id && $0.kind == kind }) {
            draft.categoryID = nil
            draft.categoryWasEdited = false
            draft.smartState.issues.append(.category)
        }
        draft.smartState.issues = Array(Set(draft.smartState.issues)).sorted { $0.rawValue < $1.rawValue }
        return draft
    }

    private func replaceQuickLogBatchDraft(_ replacement: QuickLogDraft, replacing expected: QuickLogDraft) async throws {
        guard state == .ready, quickLogDraft == expected else { throw AppModelError.transactionInProgress }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        defer { endLifecycleMutation() }
        let draftStore = try requireStore()
        await finishPendingQuickLogDraftWrite()
        try Task.checkCancellation()
        try await draftStore.upsert(replacement, id: QuickLogDraft.primaryRecordID, in: .quickLogDrafts)
        quickLogDraft = replacement
        quickLogPreparationRevision &+= 1
    }

    /// Only an explicit item token may consume a batch. An unrelated journal
    /// write retains the whole queue. The returned draft commits with the entry.
    func quickLogDraftAfterCommit(current: QuickLogDraft?, batchToken: QuickLogBatchToken?) throws -> QuickLogDraft? {
        guard let batchToken else { return current?.batch == nil ? nil : current }
        guard let current, let batch = current.batch, batch.token == batchToken else {
            throw AppModelError.transactionInProgress
        }
        return try batch.removingCurrent(current).map(validatedBatchDraft)
    }
}
