import Foundation
import MoneyUpCore

extension AppModel {
    /// Every currency this book can put on screen.
    ///
    /// Accounts, priced holdings, and saved rates each introduce a currency the
    /// user will read an amount in, so all three decide whether a bare symbol
    /// is still enough to identify one.
    var currenciesInUse: Set<CurrencyCode> {
        var currencies: Set<CurrencyCode> = []
        if let base = profile?.baseCurrency { currencies.insert(base) }
        for account in allUserAccounts {
            if let currency = account.currency { currencies.insert(currency) }
        }
        for holding in investmentHoldings {
            if let currency = holding.price?.currency { currencies.insert(currency) }
        }
        for rate in exchangeRates {
            currencies.insert(rate.baseCurrency)
            currencies.insert(rate.quoteCurrency)
        }
        return currencies
    }

    /// Republishes the book-wide currency-writing rule.
    ///
    /// Called from every setter that can change the currency set, so adding a
    /// second currency immediately switches ambiguous amounts to ISO codes
    /// without the user reopening a screen.
    func refreshMoneyDisplayPolicy() {
        guard let profile else {
            MoneyDisplayPolicy.reset()
            return
        }
        MoneyDisplayPolicy.update(
            preference: profile.currencyDisplay,
            currenciesInUse: currenciesInUse
        )
    }

    func updateCurrencyDisplay(_ display: MoneyCurrencyDisplay) async throws {
        try await mutateProfile { $0.currencyDisplay = display }
    }
}
