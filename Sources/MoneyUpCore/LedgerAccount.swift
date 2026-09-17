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
    /// Stored value that can be spent only under an allowance policy. It is a
    /// real ledger asset, but never unrestricted cash.
    case restrictedAllowance = "restricted_allowance"
    case creditCard = "credit_card"
    case loan
    case brokerage
    case investment
    case other

    /// Whether this account can fund general spending without a policy gate.
    /// Callers must still check the account kind and current balance.
    public var isUnrestrictedLiquidity: Bool {
        switch self {
        case .cash, .bank, .eWallet, .other:
            true
        case .restrictedAllowance, .creditCard, .loan, .brokerage, .investment:
            false
        }
    }
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
    /// Controls new-entry choices only; balances, budgets and history ignore it.
    public var isHiddenFromEntry: Bool
    /// Optional provenance for an explicitly enabled catalogue preset.
    public var presetID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: LedgerAccountKind,
        currency: CurrencyCode? = nil,
        accountType: FinancialAccountType? = nil,
        systemRole: SystemAccountRole? = nil,
        parentID: UUID? = nil,
        isArchived: Bool = false,
        isHiddenFromEntry: Bool = false,
        presetID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currency = currency
        self.accountType = accountType
        self.systemRole = systemRole
        self.parentID = parentID
        self.isArchived = isArchived
        self.isHiddenFromEntry = isHiddenFromEntry
        self.presetID = presetID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, currency, accountType, systemRole, parentID, isArchived
        case isHiddenFromEntry, presetID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try values.decodeIfPresent(String.self, forKey: .presetID)
        guard Self.isValidPresetID(preset) else {
            throw DecodingError.dataCorruptedError(forKey: .presetID, in: values,
                debugDescription: "Invalid entry preset identifier")
        }
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            kind: try values.decode(LedgerAccountKind.self, forKey: .kind),
            currency: try values.decodeIfPresent(CurrencyCode.self, forKey: .currency),
            accountType: try values.decodeIfPresent(FinancialAccountType.self, forKey: .accountType),
            systemRole: try values.decodeIfPresent(SystemAccountRole.self, forKey: .systemRole),
            parentID: try values.decodeIfPresent(UUID.self, forKey: .parentID),
            isArchived: try values.decode(Bool.self, forKey: .isArchived),
            isHiddenFromEntry: try values.decodeIfPresent(Bool.self, forKey: .isHiddenFromEntry) ?? false,
            presetID: preset
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard Self.isValidPresetID(presetID) else {
            throw EncodingError.invalidValue(presetID as Any, .init(codingPath: encoder.codingPath,
                debugDescription: "Invalid entry preset identifier"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(currency, forKey: .currency)
        try values.encodeIfPresent(accountType, forKey: .accountType)
        try values.encodeIfPresent(systemRole, forKey: .systemRole)
        try values.encodeIfPresent(parentID, forKey: .parentID)
        try values.encode(isArchived, forKey: .isArchived)
        if isHiddenFromEntry { try values.encode(true, forKey: .isHiddenFromEntry) }
        try values.encodeIfPresent(presetID, forKey: .presetID)
    }

    private static func isValidPresetID(_ value: String?) -> Bool {
        guard let value else { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return !value.isEmpty && value.utf8.count <= 80
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
