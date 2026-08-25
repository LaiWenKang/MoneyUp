import Foundation

/// The editable transaction state that may survive an app lock.
///
/// This value is stored only inside MoneyUp's SQLCipher database. Receipt
/// images and `PhotosPickerItem` values are deliberately excluded.
struct QuickLogDraft: Codable, Equatable, Sendable {
    static let primaryRecordID = "current"

    var kind: QuickLogKind
    var amountText: String
    var destinationAmountText: String
    var accountID: UUID?
    var destinationAccountID: UUID?
    var categoryID: UUID?
    var occurredAt: Date
    var dateWasEdited: Bool
    var payee: String
    var note: String
    var smartText: String

    var hasTransactionContent: Bool {
        !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !destinationAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !payee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !smartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || dateWasEdited
    }
}
