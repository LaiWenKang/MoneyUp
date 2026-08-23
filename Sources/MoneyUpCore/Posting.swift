import Foundation

/// One signed movement against a ledger account.
///
/// A positive or negative sign is interpreted according to the account kind by
/// reporting code. Journal validation is intentionally simpler: postings in
/// every currency must sum to exactly zero.
public struct Posting: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let money: Money
    public let memo: String?

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        money: Money,
        memo: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.money = money
        self.memo = memo
    }
}
