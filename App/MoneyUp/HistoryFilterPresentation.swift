import Foundation
import MoneyUpCore

enum HistoryCategoryScope {
    static func expanded(_ roots: Set<UUID>, in accounts: [LedgerAccount]) -> Set<UUID> {
        let children = Dictionary(grouping: accounts, by: \.parentID)
        var result = roots
        var pending = Array(roots)
        while let id = pending.popLast() {
            for child in children[id] ?? [] where result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }
}

extension HistoryFilterDraft {
    /// The visible scope already explains preset dates. The Filter badge
    /// counts predicates that require opening the advanced filter sheet.
    func advancedFilterCount(quickRange: HistoryQuickRange?) -> Int {
        let visibleDateScope = quickRange?.isRolling == true && (includesStartDate || includesEndDate)
        return activeFilterCount - (visibleDateScope ? 1 : 0)
    }

    var activeFilterCount: Int {
        [
            kind != .all, accountID != nil, categoryIDs != nil,
            categoryPostingCurrency != nil, includesStartDate || includesEndDate,
            !minimumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !maximumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ].filter { $0 }.count
    }
}
