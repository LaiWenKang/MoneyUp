import Foundation
import MoneyUpCore

/// Match the model's new-write rules without forcing an unchanged legacy
/// split to round its amounts just to edit its note or date.
enum TransactionEditSplitAmountPolicy {
    static func accepts(
        _ lines: [TransactionSplitLine],
        currency: CurrencyCode,
        preserving original: JournalEntry
    ) -> Bool {
        var seenIDs = Set<UUID>()
        return lines.allSatisfy { line in
            guard seenIDs.insert(line.id).inserted,
                  line.amount.currency == currency else { return false }
            let priorAmount = original.postings.first {
                $0.id == line.id && $0.money.currency == currency
            }.map { abs($0.money.amount) }
            do {
                try MonetaryInputPolicy.validate(
                    line.amount.amount,
                    currency: currency,
                    preserving: priorAmount
                )
                return true
            } catch {
                return false
            }
        }
    }
}
