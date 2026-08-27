import Foundation

public struct UserProfile: Codable, Equatable, Sendable {
    public static let primaryRecordID = "primary"
    public static let supportedAutoLockDelays: Set<TimeInterval> = [
        0, 60, 300, 900, 3_600
    ]
    public static let allowedAutoLockDelays = supportedAutoLockDelays

    public var baseCurrency: CurrencyCode
    public var createdAt: Date
    /// Seconds spent away from the active app before protected book data is
    /// cleared from memory. The privacy cover appears immediately regardless.
    public var autoLockDelay: TimeInterval
    public var allowLockedQuickCapture: Bool
    public var preferredAccountID: UUID?
    public var preferredExpenseCategoryID: UUID?
    public var preferredIncomeCategoryID: UUID?
    /// Opt-in gate for publishing a percentage-only snapshot to the shared
    /// widget container. Legacy profiles decode as false.
    public var showsBudgetStatusWidget: Bool
    /// Fixed Gregorian reporting zone. Legacy profiles decode as GMT so their
    /// day attribution remains deterministic rather than following travel.
    public var reportingTimeZoneIdentifier: String

    public init(
        baseCurrency: CurrencyCode,
        createdAt: Date = Date(),
        autoLockDelay: TimeInterval = 60,
        allowLockedQuickCapture: Bool = true,
        preferredAccountID: UUID? = nil,
        preferredExpenseCategoryID: UUID? = nil,
        preferredIncomeCategoryID: UUID? = nil,
        showsBudgetStatusWidget: Bool = false,
        reportingTimeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.baseCurrency = baseCurrency
        self.createdAt = createdAt
        self.autoLockDelay = Self.allowedAutoLockDelays.contains(autoLockDelay)
            ? autoLockDelay : 60
        self.allowLockedQuickCapture = allowLockedQuickCapture
        self.preferredAccountID = preferredAccountID
        self.preferredExpenseCategoryID = preferredExpenseCategoryID
        self.preferredIncomeCategoryID = preferredIncomeCategoryID
        self.showsBudgetStatusWidget = showsBudgetStatusWidget
        self.reportingTimeZoneIdentifier = TimeZone(
            identifier: reportingTimeZoneIdentifier
        )?.identifier ?? "GMT"
    }

    private enum CodingKeys: String, CodingKey {
        case baseCurrency
        case createdAt
        case autoLockDelay
        case allowLockedQuickCapture
        case preferredAccountID
        case preferredExpenseCategoryID
        case preferredIncomeCategoryID
        case showsBudgetStatusWidget
        case reportingTimeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseCurrency = try container.decode(CurrencyCode.self, forKey: .baseCurrency)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: container,
                debugDescription: "Invalid profile creation date."
            )
        }
        if container.contains(.autoLockDelay) {
            let decodedDelay = try container.decode(
                TimeInterval.self,
                forKey: .autoLockDelay
            )
            // Older builds persisted additional whole-minute choices. Keep
            // those books readable, while rejecting fractional-minute or
            // negative values that no released settings UI could create.
            guard decodedDelay.isFinite,
                  decodedDelay >= 0,
                  decodedDelay.truncatingRemainder(dividingBy: 60) == 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .autoLockDelay,
                    in: container,
                    debugDescription: "Invalid auto-lock delay."
                )
            }
            autoLockDelay = decodedDelay
        } else {
            autoLockDelay = 60
        }
        if container.contains(.allowLockedQuickCapture) {
            allowLockedQuickCapture = try container.decode(
                Bool.self,
                forKey: .allowLockedQuickCapture
            )
        } else {
            allowLockedQuickCapture = true
        }
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
        showsBudgetStatusWidget = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsBudgetStatusWidget
        ) ?? false
        if container.contains(.reportingTimeZoneIdentifier) {
            let identifier = try container.decode(
                String.self,
                forKey: .reportingTimeZoneIdentifier
            )
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .reportingTimeZoneIdentifier,
                    in: container,
                    debugDescription: "Invalid reporting time zone."
                )
            }
            reportingTimeZoneIdentifier = timeZone.identifier
        } else {
            reportingTimeZoneIdentifier = "GMT"
        }
    }
}
