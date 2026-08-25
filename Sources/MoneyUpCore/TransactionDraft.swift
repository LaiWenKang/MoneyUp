import Foundation

public enum DraftKind: String, Equatable, Sendable {
    case expense
    case income
    case refund
}

public enum DraftSource: String, Equatable, Sendable {
    case receipt
    case naturalLanguage
}

/// A proposed transaction assembled from text on the device.
///
/// Nothing here is committed. Every field is a suggestion the user reviews in
/// the quick-log sheet, so a wrong guess costs a correction rather than a bad
/// ledger entry. Fields the parser could not determine stay `nil` instead of
/// being filled with a plausible-looking default.
public struct TransactionDraft: Equatable, Sendable {
    public var kind: DraftKind
    public var amount: Decimal?
    public var occurredAt: Date?
    public var payee: String?
    public var accountID: UUID?
    public var categoryID: UUID?
    public var source: DraftSource

    public init(
        kind: DraftKind = .expense,
        amount: Decimal? = nil,
        occurredAt: Date? = nil,
        payee: String? = nil,
        accountID: UUID? = nil,
        categoryID: UUID? = nil,
        source: DraftSource
    ) {
        self.kind = kind
        self.amount = amount
        self.occurredAt = occurredAt
        self.payee = payee
        self.accountID = accountID
        self.categoryID = categoryID
        self.source = source
    }

    /// True when the parser found nothing worth prefilling, so the caller can
    /// tell the user it could not read the input instead of silently doing
    /// nothing.
    public var isEmpty: Bool {
        amount == nil && occurredAt == nil && payee == nil
    }
}
