import Foundation
import MoneyUpCore
import SwiftUI

func formattedMoney(_ money: Money) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = money.currency.value
    formatter.locale = .current
    return formatter.string(from: NSDecimalNumber(decimal: money.amount))
        ?? "\(money.currency.value) \(NSDecimalNumber(decimal: money.amount).stringValue)"
}

/// Formats a fraction such as `0.32` as a locale-aware percentage.
func formattedPercent(_ value: Decimal, fractionDigits: Int = 0) -> String {
    let number = NSDecimalNumber(decimal: value).doubleValue
    return number.formatted(
        .percent.precision(.fractionLength(0...max(0, fractionDigits)))
    )
}

func decimalAmount(from text: String) -> Decimal? {
    Decimal(string: text.trimmingCharacters(in: .whitespacesAndNewlines), locale: .current)
}

func displayMoney(for entry: JournalEntry, accounts: [LedgerAccount]) -> Money? {
    let accountKinds = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) })
    switch entry.kind {
    case .expense:
        return entry.postings.first { accountKinds[$0.accountID] == .expense }?.money
    case .income:
        return entry.postings.first { accountKinds[$0.accountID] == .income }?.money.negated
    case .transfer, .adjustment, .investment:
        return nil
    }
}

extension FinancialAccountType {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .cash: "account.type.cash"
        case .bank: "account.type.bank"
        case .eWallet: "account.type.e_wallet"
        case .creditCard: "account.type.credit_card"
        case .loan: "account.type.loan"
        case .brokerage: "account.type.brokerage"
        case .investment: "account.type.investment"
        case .other: "account.type.other"
        }
    }

    var systemImage: String {
        switch self {
        case .cash: "banknote"
        case .bank: "building.columns"
        case .eWallet: "iphone"
        case .creditCard: "creditcard"
        case .loan: "calendar.badge.exclamationmark"
        case .brokerage, .investment: "chart.line.uptrend.xyaxis"
        case .other: "wallet.bifold"
        }
    }
}

extension ReportPeriod {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .thisMonth: "period.this_month"
        case .lastMonth: "period.last_month"
        case .threeMonths: "period.three_months"
        case .sixMonths: "period.six_months"
        case .twelveMonths: "period.twelve_months"
        case .yearToDate: "period.year_to_date"
        }
    }
}
