/// One glyph per money meaning, used by the widget, Control Center, Siri
/// tiles, History, Insights, and Log alike. Signs, not directions: an arrow
/// that points up or down reads as a trend, while − and + read as money out
/// and money in.
enum MoneyUpEntryGlyph {
    static let expense = "minus"
    static let income = "plus"
    static let transfer = "arrow.left.arrow.right"
    static let refund = "arrow.uturn.backward"
    static let smartEntry = "sparkles"
    static let receipt = "receipt"
}
