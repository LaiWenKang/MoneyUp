import Foundation
import MoneyUpCore
import SwiftUI

/// A glance-privacy preference for exact financial amounts.
///
/// This is intentionally a device UI preference in `UserDefaults`, not book
/// content: the key stores one Boolean and can never contain an amount,
/// account, category, or transaction identifier. A missing preference fails
/// private so existing installs upgrading from an older build start masked.
enum MoneyAmountPrivacy {
    static let storageKey = "moneyup.privacy.hide-amounts"
    static let placeholder = "*****"
    static let defaultHidesAmounts = true

    static var hidesAmounts: Bool {
        hidesAmounts(in: .standard)
    }

    static func hidesAmounts(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultHidesAmounts
        }
        return defaults.bool(forKey: storageKey)
    }

    static func protected(_ value: String, hidesAmounts: Bool) -> String {
        hidesAmounts ? placeholder : value
    }

    static func protected(_ value: String) -> String {
        protected(value, hidesAmounts: hidesAmounts)
    }
}

/// The same one-tap privacy control on every amount-heavy top-level screen.
/// Its label describes the action while its value announces the current state.
struct MoneyUpAmountPrivacyButton: View {
    @AppStorage(MoneyAmountPrivacy.storageKey)
    private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts

    var body: some View {
        Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hidesAmounts.toggle()
            }
        } label: {
            Image(systemName: hidesAmounts ? "eye.slash.fill" : "eye.fill")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(
            hidesAmounts
                ? LocalizedStringKey("privacy.show_amounts")
                : LocalizedStringKey("privacy.hide_amounts")
        )
        .accessibilityValue(
            hidesAmounts
                ? LocalizedStringKey("privacy.amounts_hidden")
                : LocalizedStringKey("privacy.amounts_visible")
        )
        .accessibilityHint("privacy.amount_visibility_hint")
        .buttonStyle(MoneyUpPressableButtonStyle())
    }
}

private struct MoneyUpPrivateAmountInputModifier: ViewModifier {
    let isMasked: Bool
    let accessibilityLabel: Text
    let placeholderFont: Font?
    let reveal: () -> Void

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            if isMasked {
                Button(action: reveal) {
                    Text(verbatim: MoneyAmountPrivacy.placeholder)
                        .font(placeholderFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MoneyUpPressableButtonStyle())
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue("privacy.amounts_hidden")
                .accessibilityHint("privacy.tap_to_edit_amount")
            } else {
                content
            }
        }
        // Privacy changes replace the exact amount synchronously. In
        // particular, masking never cross-fades a readable value through the
        // placeholder while the rest of the screen transitions.
        .transaction { $0.animation = nil }
    }
}

extension View {
    func moneyUpPrivateAmountInput(
        masked: Bool,
        accessibilityLabel: Text,
        placeholderFont: Font? = nil,
        reveal: @escaping () -> Void
    ) -> some View {
        modifier(
            MoneyUpPrivateAmountInputModifier(
                isMasked: masked,
                accessibilityLabel: accessibilityLabel,
                placeholderFont: placeholderFont,
                reveal: reveal
            )
        )
    }
}

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
