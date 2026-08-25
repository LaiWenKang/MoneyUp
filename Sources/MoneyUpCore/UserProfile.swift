import Foundation

public struct UserProfile: Codable, Equatable, Sendable {
    public static let primaryRecordID = "primary"

    public var baseCurrency: CurrencyCode
    public var createdAt: Date
    /// Seconds spent away from the active app before protected book data is
    /// cleared from memory. The privacy cover appears immediately regardless.
    public var autoLockDelay: TimeInterval
    public var allowLockedQuickCapture: Bool
    public var preferredAccountID: UUID?
    public var preferredExpenseCategoryID: UUID?
    public var preferredIncomeCategoryID: UUID?

    public init(
        baseCurrency: CurrencyCode,
        createdAt: Date = Date(),
        autoLockDelay: TimeInterval = 60,
        allowLockedQuickCapture: Bool = true,
        preferredAccountID: UUID? = nil,
        preferredExpenseCategoryID: UUID? = nil,
        preferredIncomeCategoryID: UUID? = nil
    ) {
        self.baseCurrency = baseCurrency
        self.createdAt = createdAt
        self.autoLockDelay = max(0, autoLockDelay)
        self.allowLockedQuickCapture = allowLockedQuickCapture
        self.preferredAccountID = preferredAccountID
        self.preferredExpenseCategoryID = preferredExpenseCategoryID
        self.preferredIncomeCategoryID = preferredIncomeCategoryID
    }

    private enum CodingKeys: String, CodingKey {
        case baseCurrency
        case createdAt
        case autoLockDelay
        case allowLockedQuickCapture
        case preferredAccountID
        case preferredExpenseCategoryID
        case preferredIncomeCategoryID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseCurrency = try container.decode(CurrencyCode.self, forKey: .baseCurrency)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        autoLockDelay = max(
            0,
            try container.decodeIfPresent(TimeInterval.self, forKey: .autoLockDelay) ?? 60
        )
        allowLockedQuickCapture = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowLockedQuickCapture
        ) ?? true
        preferredAccountID = try container.decodeIfPresent(
            UUID.self,
            forKey: .preferredAccountID
        )
        preferredExpenseCategoryID = try container.decodeIfPresent(
            UUID.self,
            forKey: .preferredExpenseCategoryID
        )
        preferredIncomeCategoryID = try container.decodeIfPresent(
            UUID.self,
            forKey: .preferredIncomeCategoryID
        )
    }
}
