import MoneyUpCore
import SwiftUI

struct ExchangeRateEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var baseCode = "SGD"
    @State private var quoteCode = "MYR"
    @State private var rateText = ""
    @State private var effectiveAt = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var initialDraftSignature: [String]?

    private var knownCurrencies: [CurrencyCode] {
        var currencies = Set(model.accounts.compactMap(\.currency))
        if let base = model.profile?.baseCurrency { currencies.insert(base) }
        for holding in model.investmentHoldings {
            if let currency = holding.price?.currency { currencies.insert(currency) }
        }
        for rate in model.exchangeRates {
            currencies.insert(rate.baseCurrency)
            currencies.insert(rate.quoteCurrency)
        }
        return currencies.sorted()
    }

    private var canSave: Bool {
        guard let base = try? CurrencyCode(baseCode),
              let quote = try? CurrencyCode(quoteCode),
              SupportedCurrencies.isSelectable(base.value, existing: knownCurrencies),
              SupportedCurrencies.isSelectable(quote.value, existing: knownCurrencies),
              base != quote,
              let rate = decimalAmount(from: rateText),
              rate > .zero else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MoneyUpFlowDiagram(
                        source: MoneyUpFlowNode(title: baseCode, symbol: "banknote"),
                        destination: MoneyUpFlowNode(title: quoteCode, symbol: "banknote")
                    )
                }
            Section {
                SearchableCurrencyPicker(
                    title: "fx.base_currency",
                    selection: $baseCode,
                    existing: knownCurrencies
                )
                SearchableCurrencyPicker(
                    title: "fx.quote_currency",
                    selection: $quoteCode,
                    existing: knownCurrencies
                )
                TextField("fx.quote_per_base", text: $rateText)
                    .keyboardType(.decimalPad)
                DatePicker("fx.effective_date", selection: $effectiveAt, displayedComponents: .date)

                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack { ProgressView(); Text("action.working") }
                    } else {
                        Label("fx.save_rate", systemImage: "plus.circle.fill")
                    }
                }
                .disabled(!canSave || isSaving)
            } header: {
                Text("fx.add_rate")
            } footer: {
                MoneyUpExplainer("fx.rate_detail")
            }

            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("fx.add_rate")
            .moneyUpNavigationSurface()
            .toolbar { MoneyUpKeyboardDoneToolbar() }
            .moneyUpProtectDraft(
                hasChanges: initialDraftSignature.map { $0 != draftSignature } ?? false,
                isSaving: isSaving
            )
            .disabled(isSaving)
            .onAppear {
                guard initialDraftSignature == nil else { return }
                baseCode = model.profile?.baseCurrency.value ?? baseCode
                effectiveAt = model.currentDateForUserAction()
                initialDraftSignature = draftSignature
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private var draftSignature: [String] {
        [baseCode, quoteCode, rateText, String(effectiveAt.timeIntervalSinceReferenceDate)]
    }

    private func save() async {
        guard !isSaving, let base = try? CurrencyCode(baseCode),
              let quote = try? CurrencyCode(quoteCode),
              SupportedCurrencies.isSelectable(base.value, existing: knownCurrencies),
              SupportedCurrencies.isSelectable(quote.value, existing: knownCurrencies),
              let rate = decimalAmount(from: rateText) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveExchangeRate(
                baseCurrency: base,
                quoteCurrency: quote,
                rate: rate,
                effectiveAt: effectiveAt
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

}
