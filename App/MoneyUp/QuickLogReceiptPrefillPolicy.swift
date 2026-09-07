import Foundation

enum QuickLogReceiptPrefillPolicy {
    /// Existing values belong to the user. Equality with a scan baseline only
    /// establishes freshness; it does not grant permission to replace them.
    static func protectedFields(
        draft: QuickLogDraft,
        accountWasEdited: Bool,
        categoryWasEdited: Bool
    ) -> Set<PartialKeyPath<QuickLogDraft>> {
        var fields = Set<PartialKeyPath<QuickLogDraft>>()
        if !draft.amountText.isEmpty { fields.insert(\.amountText) }
        if !draft.payee.isEmpty { fields.insert(\.payee) }
        if !draft.note.isEmpty { fields.insert(\.note) }
        if draft.dateWasEdited || draft.sourceCaptureID != nil {
            fields.insert(\.occurredAt)
        }
        if accountWasEdited { fields.insert(\.accountID) }
        if categoryWasEdited || !draft.splitLines.isEmpty {
            fields.insert(\.categoryID)
        }
        return fields
    }
}
