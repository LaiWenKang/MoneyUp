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
    var activeFilterCount: Int {
        [
            kind != .all, accountID != nil, categoryIDs != nil,
            categoryPostingCurrency != nil, includesStartDate || includesEndDate,
            !minimumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !maximumAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ].filter { $0 }.count
    }
}
