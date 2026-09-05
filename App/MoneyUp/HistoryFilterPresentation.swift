import Foundation

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
