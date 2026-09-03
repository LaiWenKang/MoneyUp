import Foundation

/// How an amount names its currency wherever money is written.
///
/// A book may hold several currencies whose locale symbol collapses to the same
/// glyph — `SGD`, `USD`, `HKD`, and `AUD` all render as a bare `$` in some
/// locales. Reading `$120.00` then tells the user nothing about which money the
/// figure is. This preference decides how that risk is resolved.
public enum MoneyCurrencyDisplay:
    String, Codable, CaseIterable, Identifiable, Sendable {
    /// Adds the ISO code only for currencies that the book itself makes
    /// ambiguous. A single-currency book keeps its familiar symbol.
    case automatic
    /// Always writes the locale symbol, even when two currencies share one.
    case symbol
    /// Always writes the ISO code, so an amount is never read in isolation.
    case code

    public var id: String { rawValue }
}

/// The two ways a resolved amount can be written.
public enum MoneyCurrencyNotation: Equatable, Sendable {
    case symbol
    case code
}

/// Decides, without any formatting or locale lookup of its own, which
/// currencies in a book must be written with their ISO code.
///
/// The caller supplies the symbol each currency would actually render with, so
/// this rule stays pure, exhaustively testable, and identical on every locale.
public enum MoneyCurrencyAmbiguity {
    /// Currencies that share a rendered symbol with at least one other
    /// currency in the same book.
    ///
    /// - Parameter symbolsByCurrency: Every currency the book can display,
    ///   mapped to the symbol the current locale renders for it.
    /// - Returns: The subset whose symbol alone cannot identify the currency.
    public static func ambiguousCurrencies(
        symbolsByCurrency: [CurrencyCode: String]
    ) -> Set<CurrencyCode> {
        var currenciesBySymbol: [String: [CurrencyCode]] = [:]
        for (currency, symbol) in symbolsByCurrency {
            let normalized = symbol.trimmingCharacters(in: .whitespaces)
            // A symbol that is already the ISO code identifies itself; a blank
            // symbol identifies nothing and is always treated as ambiguous.
            guard normalized != currency.value else { continue }
            currenciesBySymbol[normalized, default: []].append(currency)
        }
        var ambiguous: Set<CurrencyCode> = []
        for (symbol, currencies) in currenciesBySymbol
        where symbol.isEmpty || currencies.count > 1 {
            ambiguous.formUnion(currencies)
        }
        return ambiguous
    }

    /// Resolves the notation for one amount under the user's preference.
    public static func notation(
        for currency: CurrencyCode,
        preference: MoneyCurrencyDisplay,
        ambiguousCurrencies: Set<CurrencyCode>
    ) -> MoneyCurrencyNotation {
        switch preference {
        case .symbol:
            return .symbol
        case .code:
            return .code
        case .automatic:
            return ambiguousCurrencies.contains(currency) ? .code : .symbol
        }
    }
}
