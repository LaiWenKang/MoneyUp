import Foundation
import MoneyUpCore
import SwiftUI

let maximumMoneyAmountTextByteCount = 128

@MainActor
final class MoneyFormatterCache {
    static let shared = MoneyFormatterCache()
    private var formatters: [String: NumberFormatter] = [:]

    /// - Parameter notation: `.code` renders the ISO code in the locale's own
    ///   currency position, which is how an ambiguous symbol is disambiguated
    ///   without hand-assembling a string the locale would place differently.
    func currencyFormatter(
        for currency: CurrencyCode,
        locale: Locale,
        notation: MoneyCurrencyNotation
    ) -> NumberFormatter {
        let key = "\(locale.identifier)|\(currency.value)|\(notation)"
        if let formatter = formatters[key] { return formatter }

        let formatter = NumberFormatter()
        formatter.numberStyle = notation == .code ? .currencyISOCode : .currency
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
    MoneyAmountPrivacy.protected(
        unprotectedFormattedMoney(
            money,
            notation: MoneyDisplayPolicy.notation(for: money.currency)
        )
    )
}

/// VoiceOver should announce the privacy state instead of reading five star
/// characters. Call sites that provide a custom accessibility value use this
/// alongside the visually masked `formattedMoney(_:)` result.
@MainActor
func accessibleFormattedMoney(_ money: Money) -> String {
    guard !MoneyAmountPrivacy.hidesAmounts else {
        return AppLocalization.string("privacy.amounts_hidden")
    }
    return unprotectedFormattedMoney(
        money,
        notation: MoneyDisplayPolicy.notation(for: money.currency)
    )
}

@MainActor
private func unprotectedFormattedMoney(
    _ money: Money,
    notation: MoneyCurrencyNotation
) -> String {
    let formatter = MoneyFormatterCache.shared.currencyFormatter(
        for: money.currency,
        locale: .current,
        notation: notation
    )
    return formatter.string(from: NSDecimalNumber(decimal: money.amount))
        ?? "\(money.currency.value) \(NSDecimalNumber(decimal: money.amount).stringValue)"
}

/// An amount written with its ISO code regardless of the book-wide rule.
///
/// Used where an amount is read outside the surface that establishes its
/// currency — a foreign-currency line, an exchange-rate row, or an input field
/// whose value is about to be committed to a specific account.
@MainActor
func formattedMoneyWithCurrencyCode(_ money: Money) -> String {
    MoneyAmountPrivacy.protected(
        unprotectedFormattedMoney(money, notation: .code)
    )
}

/// Formats a fraction such as `0.32` as a locale-aware percentage.
func formattedPercent(_ value: Decimal, fractionDigits: Int = 0) -> String {
    let number = NSDecimalNumber(decimal: value).doubleValue
    return number.formatted(
        .percent.precision(.fractionLength(0...max(0, fractionDigits)))
    )
}

func decimalAmount(from text: String, locale: Locale = .current) -> Decimal? {
    // Decimal has 38 significant digits. The larger byte allowance leaves
    // room for a sign, separator, and pasted whitespace while keeping regex
    // and Foundation parsing work bounded on every amount field.
    guard text.utf8.count <= maximumMoneyAmountTextByteCount else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let localSeparator = locale.decimalSeparator ?? "."
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

func displayMoney(
    for entry: JournalEntry,
    accountsByID: [UUID: LedgerAccount]
) -> Money? {
    try? categoryDisplayMoney(for: entry, accountsByID: accountsByID)
}

private enum TransactionDisplayError: Error {
    case mixedCategoryCurrencies
}

/// Split transactions are one consumer event. Sum every category leg with
/// checked decimal arithmetic instead of displaying whichever posting happens
/// to appear first.
private func categoryDisplayMoney(
    for entry: JournalEntry,
    accountsByID: [UUID: LedgerAccount]
) throws -> Money? {
    let categoryKind: LedgerAccountKind
    switch entry.kind {
    case .expense: categoryKind = .expense
    case .income: categoryKind = .income
    case .transfer, .adjustment, .investment: return nil
    }

    var currency: CurrencyCode?
    var total = Decimal.zero
    for posting in entry.postings where accountsByID[posting.accountID]?.kind == categoryKind {
        if let currency, currency != posting.money.currency {
            throw TransactionDisplayError.mixedCategoryCurrencies
        }
        currency = posting.money.currency
        total = try CheckedDecimal.adding(total, posting.money.amount)
    }
    guard let currency else { return nil }
    let signedTotal = entry.kind == .income
        ? try CheckedDecimal.subtracting(.zero, total)
        : total
    return try Money(signedTotal, currency: currency)
}

enum TransactionDisplayAmountRole: Equatable {
    case expense
    case income
    case refund
    case outgoing
    case incoming
    case change
}

struct TransactionDisplayAmount: Equatable {
    let money: Money
    let role: TransactionDisplayAmountRole
}

/// Produces only user-facing financial legs. System trading, equity, and
/// gain/loss postings remain available in transaction details but never crowd
/// a compact row or make a cross-currency transfer look like one invented sum.
func transactionDisplayAmountsResult(
    for entry: JournalEntry,
    accountsByID: [UUID: LedgerAccount],
    isRefund: Bool = false
) -> DerivedValue<[TransactionDisplayAmount]> {
    do {
        switch entry.kind {
        case .expense:
            guard let money = try categoryDisplayMoney(
                for: entry,
                accountsByID: accountsByID
            ) else { return unavailableTransactionAmounts() }
            return .available([
                TransactionDisplayAmount(
                    money: isRefund ? money.negated : money,
                    role: isRefund ? .refund : .expense
                )
            ])
        case .income:
            guard let money = try categoryDisplayMoney(
                for: entry,
                accountsByID: accountsByID
            ) else { return unavailableTransactionAmounts() }
            return .available([
                TransactionDisplayAmount(money: money, role: .income)
            ])
        case .transfer:
            let amounts: [TransactionDisplayAmount] = entry.postings.compactMap {
                posting -> TransactionDisplayAmount? in
                guard let account = accountsByID[posting.accountID],
                      account.systemRole == nil,
                      account.kind == .asset || account.kind == .liability else {
                    return nil
                }
                return TransactionDisplayAmount(
                    money: posting.money.amount < .zero
                        ? posting.money.negated
                        : posting.money,
                    role: posting.money.amount < .zero ? .outgoing : .incoming
                )
            }
            guard amounts.count >= 2 else {
                return unavailableTransactionAmounts()
            }
            return .available(amounts)
        case .adjustment:
            guard let posting = entry.postings.first(where: { posting in
                guard let account = accountsByID[posting.accountID] else { return false }
                return account.systemRole == nil
                    && (account.kind == .asset || account.kind == .liability)
            }), let account = accountsByID[posting.accountID] else {
                return unavailableTransactionAmounts()
            }
            return .available([
                TransactionDisplayAmount(
                    money: account.kind == .liability
                        ? posting.money.negated
                        : posting.money,
                    role: .change
                )
            ])
        case .investment:
            let amounts: [TransactionDisplayAmount] = entry.postings.compactMap {
                posting -> TransactionDisplayAmount? in
                guard let account = accountsByID[posting.accountID],
                      account.systemRole == nil,
                      account.kind == .asset || account.kind == .liability else {
                    return nil
                }
                return TransactionDisplayAmount(money: posting.money, role: .change)
            }
            guard !amounts.isEmpty else {
                return unavailableTransactionAmounts()
            }
            return .available(amounts)
        }
    } catch {
        DerivedValueDiagnostics.record(
            .amountCalculationFailed,
            operation: "transaction-row-amounts",
            error: error
        )
        return .unavailable(.amountCalculationFailed)
    }
}

private func unavailableTransactionAmounts() -> DerivedValue<[TransactionDisplayAmount]> {
    DerivedValueDiagnostics.record(
        .amountCalculationFailed,
        operation: "transaction-row-amounts"
    )
    return .unavailable(.amountCalculationFailed)
}

@MainActor
func formattedTransactionAmount(_ amount: TransactionDisplayAmount) -> String {
    guard !MoneyAmountPrivacy.hidesAmounts else {
        return MoneyAmountPrivacy.placeholder
    }
    let absoluteMoney = amount.money.amount < .zero ? amount.money.negated : amount.money
    let value = formattedMoney(absoluteMoney)
    switch amount.role {
    case .outgoing:
        return "−\(value)"
    case .incoming:
        return "+\(value)"
    case .change:
        return amount.money.amount < .zero ? "−\(value)" : "+\(value)"
    case .expense, .income, .refund:
        return value
    }
}

@MainActor
func accessibleFormattedTransactionAmount(
    _ amount: TransactionDisplayAmount
) -> String {
    guard !MoneyAmountPrivacy.hidesAmounts else {
        return AppLocalization.string("privacy.amounts_hidden")
    }
    return formattedTransactionAmount(amount)
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
