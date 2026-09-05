import Foundation

/// Presentation choices only. Category identifiers stay in the encrypted
/// profile and never enter shared widget defaults or a financial calculation.
public struct MoneyUpDisplayPreferences: Codable, Equatable, Sendable {
    public var showsDailyGuidance: Bool
    public var hiddenGuidanceCategoryIDs: Set<UUID>
    public var showsIllustrations: Bool
    public var showsTodayTrend: Bool
    public var reducesMotion: Bool

    public init(
        showsDailyGuidance: Bool = true,
        hiddenGuidanceCategoryIDs: Set<UUID> = [],
        showsIllustrations: Bool = true,
        showsTodayTrend: Bool = true,
        reducesMotion: Bool = false
    ) {
        self.showsDailyGuidance = showsDailyGuidance
        self.hiddenGuidanceCategoryIDs = hiddenGuidanceCategoryIDs
        self.showsIllustrations = showsIllustrations
        self.showsTodayTrend = showsTodayTrend
        self.reducesMotion = reducesMotion
    }

    public func showsGuidance(for categoryID: UUID) -> Bool {
        showsDailyGuidance && !hiddenGuidanceCategoryIDs.contains(categoryID)
    }

    public mutating func setGuidanceVisible(_ visible: Bool, for categoryID: UUID) {
        if visible { hiddenGuidanceCategoryIDs.remove(categoryID) }
        else { hiddenGuidanceCategoryIDs.insert(categoryID) }
    }

    public mutating func removeCategory(_ id: UUID) {
        hiddenGuidanceCategoryIDs.remove(id)
    }

    /// Keep the destination's explicit presentation choice after a merge.
    public mutating func mergeCategory(_ source: UUID, into target: UUID) {
        hiddenGuidanceCategoryIDs.remove(source)
    }
}
