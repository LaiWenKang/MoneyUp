import Foundation
import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    func updateSplitLine(
        _ lineID: UUID,
        update: (inout QuickLogSplitDraftLine) -> Void
    ) {
        cancelSmartParsing()
        smartState.edited(.splits)
        cancelOnDeviceAssistance()
        guard let index = splitLines.firstIndex(where: { $0.id == lineID }) else {
            return
        }
        update(&splitLines[index])
        persistUserDraftChange { $0.splitLines = splitLines }
    }

    func removeSplitLine(_ lineID: UUID) {
        smartState.edited(.splits)
        cancelOnDeviceAssistance()
        clearSplitFocus(for: lineID)
        splitLines.removeAll { $0.id == lineID }
        persistUserDraftChange { $0.splitLines = splitLines }
    }

    func applyEqualSplit() {
        guard let amount,
              let currency = selectedAccountCurrency,
              let allocations = try? TransactionSplitCalculator.equalAmounts(
                total: Money(amount, currency: currency),
                count: splitLines.count
              ) else {
            errorMessage = AppLocalization.string("split.error.allocation")
            return
        }
        applySplitAllocations(allocations)
    }

    func rebalanceUnlockedSplits() {
        guard let amount,
              let currency = selectedAccountCurrency else { return }
        let current: [Money?] = splitLines.map { line in
            guard let value = decimalAmount(from: line.amountText) else { return nil }
            return try? Money(value, currency: currency)
        }
        guard let allocations = try? TransactionSplitCalculator.rebalancedAmounts(
            total: Money(amount, currency: currency),
            current: current,
            locked: splitLines.map(\.isLocked)
        ) else {
            errorMessage = AppLocalization.string("split.error.allocation")
            return
        }
        applySplitAllocations(allocations)
    }

    func applyPercentageSplit(_ percentages: [Decimal]) {
        guard let amount,
              let currency = selectedAccountCurrency,
              let allocations = try? TransactionSplitCalculator.percentageAmounts(
                total: Money(amount, currency: currency),
                percentages: percentages
              ) else {
            errorMessage = AppLocalization.string("split.error.allocation")
            return
        }
        applySplitAllocations(allocations)
    }

    func applySplitAllocations(_ allocations: [Money]) {
        smartState.edited(.splits)
        guard allocations.count == splitLines.count else { return }
        for index in splitLines.indices {
            splitLines[index].amountText = editableAmount(allocations[index].amount)
        }
        errorMessage = nil
        persistUserDraftChange { $0.splitLines = splitLines }
    }
}
