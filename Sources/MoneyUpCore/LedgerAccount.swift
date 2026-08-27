import Foundation

public enum LedgerAccountKind: String, Codable, CaseIterable, Sendable {
    case asset
    case liability
    case income
    case expense
    case equity
    case trading
}

public enum FinancialAccountType: String, Codable, CaseIterable, Sendable {
    case cash
    case bank
    case eWallet = "e_wallet"
    case creditCard = "credit_card"
    case loan
    case brokerage
    case investment
    case other
}

public enum SystemAccountRole: String, Codable, Sendable {
    case openingBalances = "opening_balances"
    case foreignExchange = "foreign_exchange"
    /// A hidden asset account carrying one holding's current ledger value.
    /// Keeping positions in the journal makes invested cash and positions one
    /// source of net worth instead of two values that can be added twice.
    case investmentPosition = "investment_position"
    /// Counter-account for market-value and disposal movements. Entries using
    /// this role are investment events, never ordinary income or spending.
    case investmentGainLoss = "investment_gain_loss"
}

/// The accounting account behind a user-facing bank account, liability,
/// category, investment account, or foreign-exchange clearing account.
public struct LedgerAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: LedgerAccountKind
    public var currency: CurrencyCode?
    public var accountType: FinancialAccountType?
    public var systemRole: SystemAccountRole?
    public var parentID: UUID?
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: LedgerAccountKind,
        currency: CurrencyCode? = nil,
        accountType: FinancialAccountType? = nil,
        systemRole: SystemAccountRole? = nil,
        parentID: UUID? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currency = currency
        self.accountType = accountType
        self.systemRole = systemRole
        self.parentID = parentID
        self.isArchived = isArchived
    }
}
