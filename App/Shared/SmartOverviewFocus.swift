import Foundation

/// Per-widget presentation preference. These closed values contain no records
/// and do not expand the shared financial snapshot.
enum SmartOverviewFocus: String, CaseIterable, Sendable {
    case automatic, budget, review, allowance, commitments
}

extension SmartOverviewWidgetPresentation {
    func spotlight(for focus: SmartOverviewFocus) -> Component {
        guard !budget.requiresSettingsEnablement, !budget.canRefreshByOpeningApp else { return .budget }
        switch focus {
        case .budget: return .budget
        case .review where reviewCount != nil: return .review
        case .allowance where allowancePercentRemaining != nil: return .allowance
        case .commitments where activeCommitmentCount != nil: return .commitment
        default: break
        }
        // Due-day zero refers to the next scheduled expense, not every active
        // commitment. Neither a percentage nor a count implies cash sufficiency.
        if case .active(_, daysUntilNext: 0) = commitment { return .commitment }
        if case let .available(percentUsed) = budget, percentUsed > 100 { return .budget }
        if case .negativeBudget = budget { return .budget }
        if let reviewCount, reviewCount > 0 { return .review }
        if case .available = budget { return .budget }
        if case .active = commitment { return .commitment }
        if allowancePercentRemaining != nil { return .allowance }
        return .budget
    }

    func supportingComponents(for focus: SmartOverviewFocus) -> [Component] {
        guard !budget.requiresSettingsEnablement, !budget.canRefreshByOpeningApp else { return [] }
        let primary = spotlight(for: focus)
        return [.budget, .commitment, .review, .allowance].filter { component in
            guard component != primary else { return false }
            switch component {
            case .budget: return true
            case .review: return reviewCount != nil
            case .allowance: return allowancePercentRemaining != nil
            case .commitment: return activeCommitmentCount != nil
            }
        }
    }
}
