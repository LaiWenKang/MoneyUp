import Foundation

public struct UserProfile: Codable, Equatable, Sendable {
    public static let primaryRecordID = "primary"

    public var baseCurrency: CurrencyCode
    public var createdAt: Date
    public var lockWhenBackgrounded: Bool

    public init(
        baseCurrency: CurrencyCode,
        createdAt: Date = Date(),
        lockWhenBackgrounded: Bool = true
    ) {
        self.baseCurrency = baseCurrency
        self.createdAt = createdAt
        self.lockWhenBackgrounded = lockWhenBackgrounded
    }
}
