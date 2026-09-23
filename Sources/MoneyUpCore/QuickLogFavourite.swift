import Foundation

/// A saved Quick Log shortcut such as "Lunch" or "Coffee · 3.20".
///
/// A favourite only prefills the Log form; it never posts by itself. It lives
/// inside the encrypted profile record and is never published to a widget,
/// control, Siri, or any other platform surface. Account and category are
/// references, not copies: a reference that no longer resolves is left for
/// the user to choose again rather than silently reassigned.
public struct QuickLogFavourite: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case expense
        case income
    }

    /// One row of chips on a phone and one short management list.
    public static let maximumCount = 12
    public static let maximumNameLength = 40
    public static let maximumPayeeLength = 120
    public static let maximumNoteLength = 280
    /// Mirrors the Log form's practical ceiling for one typed amount.
    public static let maximumAmount: Decimal = 999_999_999_999

    public let id: UUID
    public var name: String
    public var kind: Kind
    /// `nil` means the favourite asks for the amount each time.
    public var amount: Decimal?
    public var accountID: UUID?
    public var categoryID: UUID?
    public var payee: String
    public var note: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        amount: Decimal? = nil,
        accountID: UUID? = nil,
        categoryID: UUID? = nil,
        payee: String = "",
        note: String = ""
    ) {
        self.id = id
        self.name = Self.bounded(name, to: Self.maximumNameLength)
        self.kind = kind
        self.amount = Self.normalizedAmount(amount)
        self.accountID = accountID
        self.categoryID = categoryID
        self.payee = Self.bounded(payee, to: Self.maximumPayeeLength)
        self.note = Self.bounded(note, to: Self.maximumNoteLength)
    }

    /// A fixed-amount favourite fills every field; an amount-only favourite
    /// leaves the amount for the user.
    public var hasFixedAmount: Bool { amount != nil }

    public var isValid: Bool {
        !name.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, amount, accountID, categoryID, payee, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(Kind.self, forKey: .kind),
            amount: try container.decodeIfPresent(Decimal.self, forKey: .amount),
            accountID: try container.decodeIfPresent(UUID.self, forKey: .accountID),
            categoryID: try container.decodeIfPresent(UUID.self, forKey: .categoryID),
            payee: try container.decodeIfPresent(String.self, forKey: .payee) ?? "",
            note: try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(accountID, forKey: .accountID)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        if !payee.isEmpty { try container.encode(payee, forKey: .payee) }
        if !note.isEmpty { try container.encode(note, forKey: .note) }
    }

    /// Keeps the user's order, drops blanks and repeated identifiers, and caps
    /// the list so the Log strip and the profile record both stay small.
    public static func normalized(_ candidates: [QuickLogFavourite]) -> [QuickLogFavourite] {
        var seen = Set<UUID>()
        var ordered: [QuickLogFavourite] = []
        for candidate in candidates where candidate.isValid && seen.insert(candidate.id).inserted {
            ordered.append(candidate)
            if ordered.count == maximumCount { break }
        }
        return ordered
    }

    /// Replaces a merged-away account or category reference everywhere.
    public static func remapping(
        _ favourites: [QuickLogFavourite],
        from sourceID: UUID,
        to targetID: UUID
    ) -> [QuickLogFavourite] {
        favourites.map { favourite in
            var updated = favourite
            if updated.accountID == sourceID { updated.accountID = targetID }
            if updated.categoryID == sourceID { updated.categoryID = targetID }
            return updated
        }
    }

    static func bounded(_ value: String, to limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }

    static func normalizedAmount(_ amount: Decimal?) -> Decimal? {
        guard let amount, !amount.isNaN, amount > 0, amount <= maximumAmount else {
            return nil
        }
        return amount
    }
}
