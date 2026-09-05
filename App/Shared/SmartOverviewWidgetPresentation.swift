import Foundation

/// Home-screen widgets trade secondary density for legibility at accessibility
/// Dynamic Type sizes. Lock-screen families already use native compact layouts
/// and do not consume this policy.
enum MoneyUpWidgetHomeDensity: Equatable, Sendable {
    case standard
    case accessibility

    var mediumQuickActionLimit: Int {
        self == .accessibility ? 1 : 4
    }

    var usesReducedBudgetStatus: Bool {
        self == .accessibility
    }
}

/// A UI-ready, record-free interpretation of one atomic widget generation.
///
/// Budget state and insight availability are intentionally independent. A
/// missing insight component must render as unavailable without hiding a
/// current budget state or implying that opening the app can enable a summary
/// the user explicitly disabled.
struct SmartOverviewWidgetPresentation: Equatable, Sendable {
    enum Family: CaseIterable, Equatable, Hashable, Sendable {
        case systemSmall
        case systemMedium
        case accessoryInline
        case accessoryCircular
        case accessoryRectangular
    }

    enum Component: Equatable, Sendable {
        case budget
        case review
        case allowance
        case commitment
    }

    enum BudgetStatus: Equatable, Sendable {
        case disabled
        case needsBudget
        case zeroBudget
        case negativeBudget
        case stale
        case available(percentUsed: Int)

        var canRefreshByOpeningApp: Bool {
            if case .stale = self { return true }
            return false
        }

        var requiresSettingsEnablement: Bool {
            if case .disabled = self { return true }
            return false
        }
    }

    enum CommitmentStatus: Equatable, Sendable {
        case unavailable
        case none
        case active(count: Int, daysUntilNext: Int?)
    }

    enum DayDistance: Equatable, Sendable {
        case unavailable
        case today
        case oneDay
        case days(Int)
    }

    let family: Family
    let homeDensity: MoneyUpWidgetHomeDensity
    let budget: BudgetStatus
    let reviewCount: Int?
    let allowancePercentRemaining: Int?
    let activeCommitmentCount: Int?
    let daysUntilNextCommitment: Int?

    var commitment: CommitmentStatus {
        guard let activeCommitmentCount else { return .unavailable }
        guard activeCommitmentCount > 0 else { return .none }
        return .active(
            count: activeCommitmentCount,
            daysUntilNext: daysUntilNextCommitment
        )
    }

    var commitmentDayDistance: DayDistance {
        guard let daysUntilNextCommitment else { return .unavailable }
        switch daysUntilNextCommitment {
        case 0:
            return .today
        case 1:
            return .oneDay
        default:
            return .days(daysUntilNextCommitment)
        }
    }

    var components: [Component] {
        if budget.requiresSettingsEnablement || budget.canRefreshByOpeningApp {
            return [.budget]
        }
        if homeDensity == .accessibility {
            switch family {
            case .systemSmall:
                return [.budget]
            case .systemMedium:
                return [.budget, .review]
            case .accessoryInline, .accessoryCircular, .accessoryRectangular:
                break
            }
        }
        switch family {
        case .systemSmall, .systemMedium:
            return [.budget, .review, .allowance, .commitment]
        case .accessoryInline:
            return [.budget, .review]
        case .accessoryCircular:
            return [.budget]
        case .accessoryRectangular:
            return [.budget, .review, .commitment]
        }
    }

    static func make(
        budget snapshot: BudgetWidgetSnapshot,
        insights: MoneyUpWidgetInsights?,
        family: Family,
        homeDensity: MoneyUpWidgetHomeDensity = .standard
    ) -> SmartOverviewWidgetPresentation {
        let budget: BudgetStatus
        switch snapshot {
        case .disabled:
            budget = .disabled
        case .needsBudget:
            budget = .needsBudget
        case .zeroBudget:
            budget = .zeroBudget
        case .negativeBudget:
            budget = .negativeBudget
        case .stale:
            budget = .stale
        case let .available(percentUsed, _):
            budget = .available(percentUsed: percentUsed)
        }

        return SmartOverviewWidgetPresentation(
            family: family,
            homeDensity: homeDensity,
            budget: budget,
            reviewCount: insights?.reviewCount,
            allowancePercentRemaining: insights?.allowancePercentRemaining,
            activeCommitmentCount: insights.map(\.activeCommitmentCount),
            daysUntilNextCommitment: insights?.daysUntilNextCommitment
        )
    }
}

enum MoneyUpWidgetTimelineSurface: Equatable, Sendable {
    case quickAction
    case budgetStatus
    case smartOverview
}

struct MoneyUpWidgetTimelineGeneration: Equatable, Sendable {
    let date: Date
    let snapshot: MoneyUpWidgetPublishedSnapshot
}

/// Projects an explicit stale generation at the first displayed-data expiry.
/// WidgetKit may defer a requested reload, so relying on `.after` alone can
/// leave an expired financial summary on screen.
enum MoneyUpWidgetTimelinePlanner {
    static func generations(
        startingAt now: Date,
        snapshot: MoneyUpWidgetPublishedSnapshot,
        surface: MoneyUpWidgetTimelineSurface
    ) -> [MoneyUpWidgetTimelineGeneration] {
        let current = MoneyUpWidgetTimelineGeneration(
            date: now,
            snapshot: snapshot
        )
        guard surface != .quickAction,
              let budgetExpiry = budgetExpiry(for: snapshot.budget) else {
            return [current]
        }

        let expiry: Date
        if surface == .smartOverview,
           let insightExpiry = snapshot.insights?.validUntil {
            expiry = min(budgetExpiry, insightExpiry)
        } else {
            expiry = budgetExpiry
        }
        guard expiry > now else { return [current] }

        return [
            current,
            MoneyUpWidgetTimelineGeneration(
                date: expiry,
                snapshot: MoneyUpWidgetPublishedSnapshot(
                    budget: .stale,
                    insights: nil
                )
            )
        ]
    }

    private static func budgetExpiry(
        for snapshot: BudgetWidgetSnapshot
    ) -> Date? {
        switch snapshot {
        case let .available(_, validUntil),
             let .needsBudget(validUntil),
             let .zeroBudget(validUntil),
             let .negativeBudget(validUntil):
            return validUntil
        case .disabled, .stale:
            return nil
        }
    }
}
