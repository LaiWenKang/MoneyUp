import AppIntents

/// A Focus can hide or show MoneyUp's amounts while it is on (Settings ›
/// Focus › a Focus › Add Filter › MoneyUp). When that Focus ends, the user's
/// own choice comes back. Only this display preference changes; the filter
/// never carries book data.
struct MoneyUpFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "focus_filter.title"
    static let description: IntentDescription? = IntentDescription("focus_filter.description")

    /// Optional, so the end of the Focus arrives as nil and restores the
    /// user's own choice.
    @Parameter(title: "focus_filter.hide_amounts")
    var hidesAmounts: Bool?

    var displayRepresentation: DisplayRepresentation {
        switch hidesAmounts {
        case true?: DisplayRepresentation(title: "focus_filter.hides")
        case false?: DisplayRepresentation(title: "focus_filter.shows")
        case nil: DisplayRepresentation(title: "focus_filter.unchanged")
        }
    }

    func perform() async throws -> some IntentResult {
        MoneyAmountPrivacy.applyFocus(hidesAmounts: hidesAmounts)
        return .result()
    }
}
