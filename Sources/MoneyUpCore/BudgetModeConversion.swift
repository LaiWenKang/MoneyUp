import Foundation

public enum BudgetModeConversion {
    /// Preserve the configured total when the user switches interpretations.
    /// Current carry is checked separately before committing the new policy.
    public static func limit(
        _ current: Money?, children: Money?, from old: BudgetAllocationMode,
        to new: BudgetAllocationMode
    ) throws -> Money? {
        guard old != new, let children else { return current }
        switch new {
        case .automatic:
            guard let current else { return nil }
            let result = try current.subtracting(children)
            guard result.amount >= .zero else { throw BudgetMergeError.overallocatedEnvelope }
            return result
        case .fixedTotal:
            return try (current ?? .zero(currency: children.currency)).adding(children)
        }
    }
}
