import SwiftUI

/// Supplemental feedback policy. Every consequential result still needs a
/// visible status; navigation and presentation never gain decorative haptics.
enum MoneyUpFeedback {
    enum Event: CaseIterable, Equatable, Sendable {
        case financialCommit
        case destructiveCommit
        case validationFailure
        case selection
        case navigation
        case presentation
    }

    enum Haptic: Equatable, Sendable {
        case none
        case success
        case warning
        case error
    }

    struct Policy: Equatable, Sendable {
        let haptic: Haptic
        let requiresVisibleStatus: Bool
    }

    static func policy(for event: Event) -> Policy {
        switch event {
        case .financialCommit:
            Policy(haptic: .success, requiresVisibleStatus: true)
        case .destructiveCommit:
            Policy(haptic: .warning, requiresVisibleStatus: true)
        case .validationFailure:
            Policy(haptic: .error, requiresVisibleStatus: true)
        case .selection, .navigation, .presentation:
            Policy(haptic: .none, requiresVisibleStatus: false)
        }
    }

    static func haptic(
        for event: Event,
        visibleStatus: Bool
    ) -> Haptic {
        let policy = policy(for: event)
        guard !policy.requiresVisibleStatus || visibleStatus else {
            return .none
        }
        return policy.haptic
    }

    /// Resolve feedback at the same transition boundary SwiftUI observes.
    /// A visible status appearing on its own is not a consequential result.
    static func haptic<Trigger: Equatable>(
        for event: Event,
        previousTrigger: Trigger,
        currentTrigger: Trigger,
        visibleStatus: Bool
    ) -> Haptic {
        guard previousTrigger != currentTrigger else {
            return .none
        }
        return haptic(for: event, visibleStatus: visibleStatus)
    }
}

extension View {
    func moneyUpFeedback<Trigger: Equatable>(
        for event: MoneyUpFeedback.Event,
        trigger: Trigger,
        visibleStatus: Bool
    ) -> some View {
        self.sensoryFeedback(trigger: trigger) { oldTrigger, newTrigger in
            switch MoneyUpFeedback.haptic(
                for: event,
                previousTrigger: oldTrigger,
                currentTrigger: newTrigger,
                visibleStatus: visibleStatus
            ) {
            case .none:
                return nil
            case .success:
                return .success
            case .warning:
                return .warning
            case .error:
                return .error
            }
        }
    }
}
