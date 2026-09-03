import Foundation
import MoneyUpCore

/// One pinned category resolved for the Today board.
///
/// `spread` is present only while there is a positive balance left to pace; an
/// exhausted or overspent category reports its overspend instead of an even
/// split of a negative number.
struct PinnedBudgetSummary: Identifiable, Equatable {
    let progress: BudgetProgress
    let purpose: BudgetPurpose
    let spread: BudgetPaceSpread?

    var id: UUID { progress.node.id }
    var node: BudgetNode { progress.node }
    var remaining: Money? { progress.remaining }
    var spent: Money { progress.spent }
    var effectiveLimit: Money? { progress.effectiveLimit }

    var isOverspent: Bool {
        guard let remaining = progress.remaining else { return false }
        return remaining.amount < .zero
    }
}

/// A budget category positioned in the category tree.
struct OutlinedBudgetNode: Identifiable, Equatable {
    let node: BudgetNode
    let depth: Int

    var id: UUID { node.id }
}

extension AppModel {
    /// Depth-first, name-ordered budget outline shared by the Plan list and the
    /// pin editor, so a category occupies the same position in both.
    ///
    /// A corrupt parent cycle is bounded by the visited set rather than
    /// recursing until the stack is exhausted.
    var budgetNodeOutline: [OutlinedBudgetNode] {
        let children = Dictionary(grouping: budgetNodes, by: \.parentID)
        var outline: [OutlinedBudgetNode] = []
        var visited = Set<UUID>()

        func appendChildren(of parentID: UUID?, depth: Int) {
            for node in (children[parentID] ?? []).sorted(by: { $0.name < $1.name })
            where visited.insert(node.id).inserted {
                outline.append(OutlinedBudgetNode(node: node, depth: depth))
                appendChildren(of: node.id, depth: depth + 1)
            }
        }
        appendChildren(of: nil, depth: 0)
        return outline
    }

    /// Pinned categories that still exist in the budget, in the user's order.
    ///
    /// A category deleted since it was pinned simply drops out; the stored list
    /// is repaired the next time the user edits their pins rather than by a
    /// write triggered from a read.
    var pinnedBudgetNodes: [BudgetNode] {
        guard let pinned = profile?.pinnedBudgetNodeIDs, !pinned.isEmpty else {
            return []
        }
        let nodesByID = Dictionary(
            budgetNodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return pinned.compactMap { nodesByID[$0] }
    }

    func isBudgetNodePinned(_ id: UUID) -> Bool {
        profile?.pinnedBudgetNodeIDs.contains(id) ?? false
    }

    var canPinAnotherBudgetNode: Bool {
        (profile?.pinnedBudgetNodeIDs.count ?? 0)
            < UserProfile.maximumPinnedBudgetNodes
    }

    /// Month, week, and day remaining for every pinned category, all resolved
    /// from one reporting instant.
    func pinnedBudgetSummariesResult(
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<[PinnedBudgetSummary]> {
        let pinned = profile?.pinnedBudgetNodeIDs ?? []
        guard !pinned.isEmpty else { return .available([]) }
        let date = requestedDate ?? currentDateForUserAction()
        let purposes = budgetPurposeOverview().effectivePurposeByID

        switch budgetProgressThisMonthResult(asOf: date) {
        case let .available(progress):
            let progressByID = Dictionary(
                progress.map { ($0.node.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var summaries: [PinnedBudgetSummary] = []
            for id in pinned {
                guard let entry = progressByID[id] else { continue }
                switch pinnedBudgetSpread(for: entry, asOf: date) {
                case let .available(spread):
                    summaries.append(
                        PinnedBudgetSummary(
                            progress: entry,
                            purpose: purposes[id] ?? entry.node.purpose,
                            spread: spread
                        )
                    )
                case let .unavailable(issue):
                    return .unavailable(issue)
                }
            }
            return .available(summaries)
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    /// Splits what is left of a category evenly across the rest of the month.
    ///
    /// Unlike `budgetPace(for:cadence:)`, which feeds discretionary guidance
    /// and is therefore restricted to flexible categories, this is a plain
    /// even split of an already-committed remainder. It never changes what the
    /// safe-to-spend figure counts as discretionary money.
    private func pinnedBudgetSpread(
        for progress: BudgetProgress,
        asOf: Date
    ) -> DerivedValue<BudgetPaceSpread?> {
        guard let remaining = progress.remaining,
              remaining.amount > .zero else { return .available(nil) }
        do {
            return .available(
                try BudgetPaceCalculator.spread(
                    remaining: remaining,
                    asOf: asOf,
                    calendar: reportingCalendar
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "pinned-budget-spread",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    /// Adds or removes one pin, keeping the user's chosen order.
    func setBudgetNodePinned(_ id: UUID, isPinned: Bool) async throws {
        guard budgetNodes.contains(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var pinned = profile?.pinnedBudgetNodeIDs ?? []
        if isPinned {
            guard !pinned.contains(id) else { return }
            guard pinned.count < UserProfile.maximumPinnedBudgetNodes else {
                throw AppModelError.invalidBook
            }
            pinned.append(id)
        } else {
            guard pinned.contains(id) else { return }
            pinned.removeAll { $0 == id }
        }
        try await updatePinnedBudgetNodes(pinned)
    }

    /// Replaces the pinned set, dropping categories the budget no longer has.
    func updatePinnedBudgetNodes(_ ids: [UUID]) async throws {
        let known = Set(budgetNodes.map(\.id))
        let retained = UserProfile.normalizedPins(ids.filter(known.contains))
        guard retained.count <= UserProfile.maximumPinnedBudgetNodes else {
            throw AppModelError.invalidBook
        }
        try await mutateProfile { $0.pinnedBudgetNodeIDs = retained }
    }
}
