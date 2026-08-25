import Foundation
import MoneyUpCore
import SwiftUI

@MainActor
private final class MoneyFormatterCache {
    static let shared = MoneyFormatterCache()
    private var formatters: [String: NumberFormatter] = [:]

    func currencyFormatter(for currency: CurrencyCode, locale: Locale) -> NumberFormatter {
        let key = locale.identifier + "|" + currency.value
        if let formatter = formatters[key] { return formatter }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.value
        formatter.locale = locale
        formatter.minimumFractionDigits = currency.minorUnits <= 3
            ? currency.minorUnits
            : 0
        formatter.maximumFractionDigits = currency.minorUnits
        formatters[key] = formatter
        return formatter
    }
}

@MainActor
func formattedMoney(_ money: Money) -> String {
    let formatter = MoneyFormatterCache.shared.currencyFormatter(
        for: money.currency,
        locale: .current
    )
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
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let localSeparator = Locale.current.decimalSeparator ?? "."
    let escapedLocal = NSRegularExpression.escapedPattern(for: localSeparator)
    let separatorPattern = localSeparator == "." ? "\\." : "(?:\(escapedLocal)|\\.)"
    let pattern = "^[+-]?[0-9]+(?:\(separatorPattern)[0-9]+)?$"
    guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
        return nil
    }
    let normalized = localSeparator == "."
        ? trimmed
        : trimmed.replacingOccurrences(of: localSeparator, with: ".")
    return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
}

func editableAmount(_ value: Decimal, locale: Locale = .current) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = locale
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 16
    formatter.generatesDecimalNumbers = true
    return formatter.string(from: NSDecimalNumber(decimal: value))
        ?? NSDecimalNumber(decimal: value).stringValue
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

extension Color {
    /// A restrained premium highlight against the royal-blue brand colour.
    /// Keep this rare so blue remains unmistakably dominant.
    static var moneyUpGold: Color { Color("GoldAccent") }
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
