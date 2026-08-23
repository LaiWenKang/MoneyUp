import Foundation

public enum LedgerAccountKind: String, Codable, CaseIterable, Sendable {
    case asset
    case liability
    case income
    case expense
    case equity
    case trading
}

/// The accounting account behind a user-facing bank account, liability,
/// category, investment account, or foreign-exchange clearing account.
public struct LedgerAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: LedgerAccountKind
    public var currency: CurrencyCode?
    public var parentID: UUID?
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: LedgerAccountKind,
        currency: CurrencyCode? = nil,
        parentID: UUID? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currency = currency
        self.parentID = parentID
        self.isArchived = isArchived
    }
}
