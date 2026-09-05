import Foundation

public struct UserProfile: Codable, Equatable, Sendable {
    public static let primaryRecordID = "primary"
    public static let supportedAutoLockDelays: Set<TimeInterval> = [
        0, 60, 300, 900, 3_600
    ]
    public static let allowedAutoLockDelays = supportedAutoLockDelays
    /// One screen of pins. The board is a focus tool, not a second budget list.
    public static let maximumPinnedBudgetNodes = 8

    public var baseCurrency: CurrencyCode
    public var createdAt: Date
    /// Seconds spent away from the active app before protected book data is
    /// cleared from memory. The privacy cover appears immediately regardless.
    public var autoLockDelay: TimeInterval
    public var allowLockedQuickCapture: Bool
    public var preferredAccountID: UUID?
    public var preferredExpenseCategoryID: UUID?
    public var preferredIncomeCategoryID: UUID?
    /// Opt-in gate for publishing a bounded, record-free status snapshot to
    /// the shared widget container. Legacy profiles decode as false.
    public var showsBudgetStatusWidget: Bool
    /// Deterministic local intelligence is enabled by default. Turning it off
    /// cancels analysis and removes its encrypted derived indexes.
    public var intelligenceEnabled: Bool
    /// Optional Apple on-device assistance for choosing from a closed list of
    /// existing Quick Log accounts and categories. It is enabled by default;
    /// unsupported devices fail closed to deterministic parsing.
    public var foundationModelAssistanceEnabled: Bool
    /// Retired compatibility value. Old payloads may still contain the key,
    /// but 0.7.1 normalizes it off and never writes it again.
    public private(set) var enablesTabSwipeNavigation: Bool
    /// Fixed Gregorian reporting zone. Legacy profiles decode as GMT so their
    /// day attribution remains deterministic rather than following travel.
    public var reportingTimeZoneIdentifier: String
    /// How money is written wherever an amount is shown. Legacy profiles decode
    /// as `.automatic`, which adds the ISO code only when the book's own
    /// currencies would otherwise share one locale symbol.
    public var currencyDisplay: MoneyCurrencyDisplay
    /// Budget categories the user promoted to the Today board, in the order
    /// they chose. Duplicates are removed and the list is bounded so the board
    /// and the profile record both stay small.
    public var pinnedBudgetNodeIDs: [UUID]
    public var displayPreferences: MoneyUpDisplayPreferences

    public init(
        baseCurrency: CurrencyCode,
        createdAt: Date = Date(),
        autoLockDelay: TimeInterval = 60,
        allowLockedQuickCapture: Bool = true,
        preferredAccountID: UUID? = nil,
        preferredExpenseCategoryID: UUID? = nil,
        preferredIncomeCategoryID: UUID? = nil,
        showsBudgetStatusWidget: Bool = false,
        intelligenceEnabled: Bool = true,
        foundationModelAssistanceEnabled: Bool = true,
        enablesTabSwipeNavigation: Bool = false,
        reportingTimeZoneIdentifier: String = TimeZone.current.identifier,
        currencyDisplay: MoneyCurrencyDisplay = .automatic,
        pinnedBudgetNodeIDs: [UUID] = [],
        displayPreferences: MoneyUpDisplayPreferences = .init()
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
        self.intelligenceEnabled = intelligenceEnabled
        self.foundationModelAssistanceEnabled = foundationModelAssistanceEnabled
        self.enablesTabSwipeNavigation = false
        self.reportingTimeZoneIdentifier = TimeZone(
            identifier: reportingTimeZoneIdentifier
        )?.identifier ?? "GMT"
        self.currencyDisplay = currencyDisplay
        self.pinnedBudgetNodeIDs = Self.normalizedPins(pinnedBudgetNodeIDs)
        self.displayPreferences = displayPreferences
    }

    /// Keeps the stored order the user chose while removing repeats and
    /// capping the board so one screen can always show every pin.
    public static func normalizedPins(_ candidates: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for candidate in candidates where seen.insert(candidate).inserted {
            ordered.append(candidate)
            if ordered.count == maximumPinnedBudgetNodes { break }
        }
        return ordered
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
        case intelligenceEnabled
        case foundationModelAssistanceEnabled
        case enablesTabSwipeNavigation
        case reportingTimeZoneIdentifier
        case currencyDisplay
        case pinnedBudgetNodeIDs
        case displayPreferences
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
        autoLockDelay = try Self.decodedAutoLockDelay(from: container)
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
        intelligenceEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .intelligenceEnabled
        ) ?? true
        foundationModelAssistanceEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .foundationModelAssistanceEnabled
        ) ?? true
        if container.contains(.enablesTabSwipeNavigation) {
            _ = try container.decode(
                Bool.self,
                forKey: .enablesTabSwipeNavigation
            )
        }
        enablesTabSwipeNavigation = false
        reportingTimeZoneIdentifier = try Self.decodedReportingTimeZone(
            from: container
        )
        currencyDisplay = try container.decodeIfPresent(
            MoneyCurrencyDisplay.self,
            forKey: .currencyDisplay
        ) ?? .automatic
        pinnedBudgetNodeIDs = Self.normalizedPins(
            try container.decodeIfPresent(
                [UUID].self,
                forKey: .pinnedBudgetNodeIDs
            ) ?? []
        )
        displayPreferences = try container.decodeIfPresent(
            MoneyUpDisplayPreferences.self, forKey: .displayPreferences
        ) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseCurrency, forKey: .baseCurrency)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(autoLockDelay, forKey: .autoLockDelay)
        try container.encode(
            allowLockedQuickCapture,
            forKey: .allowLockedQuickCapture
        )
        try container.encodeIfPresent(
            preferredAccountID,
            forKey: .preferredAccountID
        )
        try container.encodeIfPresent(
            preferredExpenseCategoryID,
            forKey: .preferredExpenseCategoryID
        )
        try container.encodeIfPresent(
            preferredIncomeCategoryID,
            forKey: .preferredIncomeCategoryID
        )
        try container.encode(
            showsBudgetStatusWidget,
            forKey: .showsBudgetStatusWidget
        )
        try container.encode(intelligenceEnabled, forKey: .intelligenceEnabled)
        try container.encode(
            foundationModelAssistanceEnabled,
            forKey: .foundationModelAssistanceEnabled
        )
        try container.encode(
            reportingTimeZoneIdentifier,
            forKey: .reportingTimeZoneIdentifier
        )
        try container.encode(currencyDisplay, forKey: .currencyDisplay)
        try container.encode(pinnedBudgetNodeIDs, forKey: .pinnedBudgetNodeIDs)
        try container.encode(displayPreferences, forKey: .displayPreferences)
    }

    /// Older builds persisted additional whole-minute choices. Keep those books
    /// readable, while rejecting fractional-minute or negative values that no
    /// released settings UI could create.
    private static func decodedAutoLockDelay(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> TimeInterval {
        guard container.contains(.autoLockDelay) else { return 60 }
        let decoded = try container.decode(
            TimeInterval.self,
            forKey: .autoLockDelay
        )
        guard decoded.isFinite,
              decoded >= 0,
              decoded.truncatingRemainder(dividingBy: 60) == 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .autoLockDelay,
                in: container,
                debugDescription: "Invalid auto-lock delay."
            )
        }
        return decoded
    }

    /// Profiles written before the fixed reporting zone existed decode as GMT
    /// so their day attribution stays deterministic rather than following the
    /// device the book is opened on.
    private static func decodedReportingTimeZone(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        guard container.contains(.reportingTimeZoneIdentifier) else {
            return "GMT"
        }
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
        return timeZone.identifier
    }
}
