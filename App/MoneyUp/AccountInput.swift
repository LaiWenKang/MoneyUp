import MoneyUpCore
import SwiftUI

extension FinancialAccountType {
    var isLiabilityAccount: Bool {
        self == .creditCard || self == .loan
    }

    var openingBalanceLabel: LocalizedStringKey {
        isLiabilityAccount
            ? "account.amount_owed_optional"
            : "account.current_balance_optional"
    }

    var openingBalanceGuidance: LocalizedStringKey {
        if isLiabilityAccount {
            return "account.amount_owed_detail"
        }
        if self == .brokerage || self == .investment {
            return "account.investment_cash_detail"
        }
        return "account.current_balance_detail"
    }
}

/// Empty input means zero. Asset accounts accept a negative current balance
/// for an overdraft; a liability is entered as a non-negative amount owed.
func parsedOpeningBalance(
    from text: String,
    accountType: FinancialAccountType
) -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .zero }
    guard let value = decimalAmount(from: trimmed) else { return nil }
    guard !accountType.isLiabilityAccount || value >= .zero else { return nil }
    return value
}
