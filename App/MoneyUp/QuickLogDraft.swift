import Foundation

struct QuickLogSplitDraftLine: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var categoryID: UUID?
    var amountText: String
    var memo: String
    var isLocked: Bool

    init(
        id: UUID = UUID(),
        categoryID: UUID? = nil,
        amountText: String = "",
        memo: String = "",
        isLocked: Bool = false
    ) {
        self.id = id
        self.categoryID = categoryID
        self.amountText = amountText
        self.memo = memo
        self.isLocked = isLocked
    }

    private enum CodingKeys: String, CodingKey {
        case id, categoryID, amountText, memo, isLocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        amountText = try container.decode(String.self, forKey: .amountText)
        memo = try container.decode(String.self, forKey: .memo)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

/// The editable transaction state that may survive an app lock.
///
/// This value is stored only inside MoneyUp's SQLCipher database. Receipt
/// images and `PhotosPickerItem` values are deliberately excluded.
struct QuickLogDraft: Codable, Equatable, Sendable {
    static let primaryRecordID = "current"
    static let maximumSplitLineCount = 512

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
    var splitLines: [QuickLogSplitDraftLine]
    var selectedAllowanceID: UUID?
    /// Present only when this draft originated in the no-authentication capture
    /// inbox. Once copied into SQLCipher the inbox copy is deleted.
    var sourceCaptureID: UUID? = nil

    init(
        kind: QuickLogKind,
        amountText: String,
        destinationAmountText: String,
        accountID: UUID?,
        destinationAccountID: UUID?,
        categoryID: UUID?,
        occurredAt: Date,
        dateWasEdited: Bool,
        payee: String,
        note: String,
        smartText: String,
        splitLines: [QuickLogSplitDraftLine] = [],
        selectedAllowanceID: UUID? = nil,
        sourceCaptureID: UUID? = nil
    ) {
        self.kind = kind
        self.amountText = amountText
        self.destinationAmountText = destinationAmountText
        self.accountID = accountID
        self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID
        self.occurredAt = occurredAt
        self.dateWasEdited = dateWasEdited
        self.payee = payee
        self.note = note
        self.smartText = smartText
        self.splitLines = splitLines
        self.selectedAllowanceID = selectedAllowanceID
        self.sourceCaptureID = sourceCaptureID
    }

    var hasTransactionContent: Bool {
        !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !destinationAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !payee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !smartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || splitLines.contains {
                $0.categoryID != nil
                    || !$0.amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            || selectedAllowanceID != nil
            || dateWasEdited
    }

    private enum CodingKeys: String, CodingKey {
        case kind, amountText, destinationAmountText, accountID, destinationAccountID
        case categoryID, occurredAt, dateWasEdited, payee, note, smartText
        case splitLines, selectedAllowanceID, sourceCaptureID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(QuickLogKind.self, forKey: .kind)
        amountText = try container.decode(String.self, forKey: .amountText)
        destinationAmountText = try container.decode(String.self, forKey: .destinationAmountText)
        accountID = try container.decodeIfPresent(UUID.self, forKey: .accountID)
        destinationAccountID = try container.decodeIfPresent(UUID.self, forKey: .destinationAccountID)
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        dateWasEdited = try container.decode(Bool.self, forKey: .dateWasEdited)
        payee = try container.decode(String.self, forKey: .payee)
        note = try container.decode(String.self, forKey: .note)
        smartText = try container.decode(String.self, forKey: .smartText)
        splitLines = try container.decodeIfPresent(
            [QuickLogSplitDraftLine].self,
            forKey: .splitLines
        ) ?? []
        guard splitLines.count <= Self.maximumSplitLineCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .splitLines,
                in: container,
                debugDescription: "Quick Log split limit exceeded"
            )
        }
        selectedAllowanceID = try container.decodeIfPresent(
            UUID.self,
            forKey: .selectedAllowanceID
        )
        sourceCaptureID = try container.decodeIfPresent(UUID.self, forKey: .sourceCaptureID)
    }
}
