import Foundation
import MoneyUpCore
import SwiftUI

/// The resolved currency-writing rule shared by every money label in the app.
///
/// The rule is book-wide state — it depends on which currencies the user's own
/// accounts, holdings, and rates hold — so it is published once by `AppModel`
/// rather than threaded through the several hundred call sites of
/// `formattedMoney(_:)`. It is `@MainActor`, matching both `AppModel` and the
/// formatter cache, so there is no shared mutable state across isolation
/// domains.
@MainActor
enum MoneyDisplayPolicy {
    private(set) static var preference: MoneyCurrencyDisplay = .automatic
    private(set) static var ambiguousCurrencies: Set<CurrencyCode> = []
    private(set) static var currencyCount = 0

    /// True once a book holds more than one currency, after which naming an
    /// account without naming its currency hides a currency change.
    static var namesAccountCurrency: Bool { currencyCount > 1 }

    /// Recomputes the rule from the currencies a book can actually display.
    ///
    /// - Parameters:
    ///   - preference: The user's stored choice.
    ///   - currenciesInUse: Every currency the book can show an amount in.
    ///   - locale: The locale whose symbols the formatter will use.
    static func update(
        preference: MoneyCurrencyDisplay,
        currenciesInUse: some Sequence<CurrencyCode>,
        locale: Locale = .current
    ) {
        self.preference = preference
        let symbolsByCurrency = Dictionary(
            currenciesInUse.map { ($0, currencySymbol(for: $0, locale: locale)) },
            uniquingKeysWith: { first, _ in first }
        )
        currencyCount = symbolsByCurrency.count
        ambiguousCurrencies = MoneyCurrencyAmbiguity.ambiguousCurrencies(
            symbolsByCurrency: symbolsByCurrency
        )
    }

    static func notation(for currency: CurrencyCode) -> MoneyCurrencyNotation {
        MoneyCurrencyAmbiguity.notation(
            for: currency,
            preference: preference,
            ambiguousCurrencies: ambiguousCurrencies
        )
    }

    /// Resets to the launch rule. Locking or erasing a book must not leave a
    /// previous book's currency set describing the next one.
    static func reset() {
        preference = .automatic
        ambiguousCurrencies = []
        currencyCount = 0
    }

    private static func currencySymbol(
        for currency: CurrencyCode,
        locale: Locale
    ) -> String {
        MoneyFormatterCache.shared.currencyFormatter(
            for: currency,
            locale: locale,
            notation: .symbol
        ).currencySymbol ?? ""
    }
}

extension MoneyCurrencyDisplay {
    var titleKey: LocalizedStringKey {
        switch self {
        case .automatic: "settings.currency_display.automatic"
        case .symbol: "settings.currency_display.symbol"
        case .code: "settings.currency_display.code"
        }
    }

    var detailKey: LocalizedStringKey {
        switch self {
        case .automatic: "settings.currency_display.automatic_detail"
        case .symbol: "settings.currency_display.symbol_detail"
        case .code: "settings.currency_display.code_detail"
        }
    }
}

/// Names an account's currency once a book holds more than one, so choosing an
/// account in a picker is never a silent change to the currency of the money
/// being entered. A single-currency book keeps the plain account name.
@MainActor
func accountCurrencyLabel(_ account: LedgerAccount) -> String {
    guard MoneyDisplayPolicy.namesAccountCurrency,
          let currency = account.currency else { return account.name }
    return "\(account.name) · \(currency.value)"
}
