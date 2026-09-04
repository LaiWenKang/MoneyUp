import MoneyUpCore
import SwiftUI

/// Settings for how money is written, plus a live sample of every currency the
/// book actually holds so the choice can be judged rather than guessed.
struct CurrencySettingsSection: View {
    /// A recognisable amount that exercises grouping and the minor units of
    /// whichever currency renders it.
    private static let sampleSignificand = 123_456
    /// Enough to demonstrate the choice on a mixed-currency book without
    /// turning Settings into a currency list.
    private static let maximumPreviewedCurrencies = 4

    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?

    private var baseCurrency: CurrencyCode? { model.profile?.baseCurrency }

    private var selectedDisplay: MoneyCurrencyDisplay {
        model.profile?.currencyDisplay ?? .automatic
    }

    private var previewedCurrencies: [CurrencyCode] {
        let base = baseCurrency
        let ordered = model.currenciesInUse
            .sorted { left, right in
                if (left == base) != (right == base) { return left == base }
                return left < right
            }
            .prefix(Self.maximumPreviewedCurrencies)
        return Array(ordered)
    }

    private func sample(for currency: CurrencyCode) -> Money? {
        try? Money(
            Decimal(
                sign: .plus,
                exponent: -currency.minorUnits,
                significand: Decimal(Self.sampleSignificand)
            ),
            currency: currency
        )
    }

    var body: some View {
        Section {
            if let baseCurrency {
                LabeledContent("settings.base_currency") {
                    Text(currencyLabel(baseCurrency))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            Picker(
                "settings.currency_display",
                selection: Binding(
                    get: { selectedDisplay },
                    set: { display in
                        Task { await apply(display) }
                    }
                )
            ) {
                ForEach(MoneyCurrencyDisplay.allCases) { display in
                    Text(display.titleKey).tag(display)
                }
            }
            .accessibilityHint(selectedDisplay.detailKey)
            .moneyUpOperationErrorAlert(message: $errorMessage)

            ForEach(previewedCurrencies, id: \.self) { currency in
                if let sample = sample(for: currency) {
                    LabeledContent(currencyLabel(currency)) {
                        Text(formattedMoney(sample))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            NavigationLink {
                ExchangeRatesView()
            } label: {
                Label("fx.title", systemImage: "arrow.left.arrow.right.circle")
            }
        } header: {
            Text("settings.currency_section")
        } footer: {
            MoneyUpExplainer("settings.currency_section_detail")
        }
    }

    private func currencyLabel(_ currency: CurrencyCode) -> String {
        guard let name = SupportedCurrencies.localizedName(for: currency.value) else {
            return currency.value
        }
        return "\(currency.value) · \(name)"
    }

    private func apply(_ display: MoneyCurrencyDisplay) async {
        do {
            try await model.updateCurrencyDisplay(display)
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
