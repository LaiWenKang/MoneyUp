import MoneyUpCore

extension AppModel {
    func adoptUnlockToFirstUsefulContentInterval(
        _ interval: MoneyUpPerformanceInterval?
    ) {
        finishUnlockToFirstUsefulContentMeasurement(outcome: .cancelled)
        unlockToFirstUsefulContentInterval = interval
    }

    func finishUnlockToFirstUsefulContentMeasurement(
        outcome: MoneyUpPerformanceOutcome = .cancelled
    ) {
        let interval = unlockToFirstUsefulContentInterval
        unlockToFirstUsefulContentInterval = nil
        MoneyUpPerformanceSignposts.end(interval, outcome: outcome)
    }
}
