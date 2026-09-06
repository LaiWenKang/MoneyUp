import Observation

/// Process-local navigation survives cold startup and authentication. It
/// cannot reveal data or create a transaction, and is never written to disk.
@MainActor @Observable
final class MoneyUpOverviewNavigation {
    private(set) var pending: MoneyUpOverviewRoute?

    func request(_ destination: MoneyUpOverviewRoute) {
        pending = destination
    }

    func consume(isReady: Bool, isActive: Bool, isCovered: Bool) -> MoneyUpOverviewRoute? {
        guard isReady, isActive, !isCovered else { return nil }
        defer { pending = nil }
        return pending
    }
}

/// Scene activation can arrive after WindowGroup's first task. Claiming the
/// initial start once avoids overlapping authentication attempts; an inactive
/// scene can defer the claim without losing it.
@MainActor @Observable
final class MoneyUpSceneLaunchState {
    var isActive = false
    private(set) var isStarting = false
    private(set) var didStart = false

    func claim(isLaunching: Bool) -> Bool {
        guard isActive, isLaunching, !isStarting, !didStart else { return false }
        isStarting = true
        return true
    }

    func finish(wasDeferred: Bool) {
        isStarting = false
        didStart = !wasDeferred
    }
}
