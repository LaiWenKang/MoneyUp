import Observation

/// One in-memory selection owner lets navigation change without replacing the
/// permanent tab hierarchy. It is recreated when RootView discards the book UI.
@MainActor @Observable
final class MoneyUpTabNavigation {
    var section: MoneyUpSection
    init(section: MoneyUpSection = .today) { self.section = section }
}
