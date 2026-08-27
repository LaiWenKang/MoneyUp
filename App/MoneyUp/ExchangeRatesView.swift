import MoneyUpCore
import SwiftUI

struct ExchangeRatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var baseCode = "SGD"
    @State private var quoteCode = "MYR"
    @State private var rateText = ""
    @State private var effectiveAt = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingDeletionID: UUID?
    @State private var isConfirmingDeletion = false

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
        Form {
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
                Text("fx.rate_detail")
            }

            Section {
                if model.exchangeRates.isEmpty {
                    ContentUnavailableView(
                        "fx.no_rates",
                        systemImage: "equal.circle",
                        description: Text("fx.unconverted_detail")
                    )
                } else {
                    ForEach(model.exchangeRates) { rate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(rate.baseCurrency.value) → \(rate.quoteCurrency.value)")
                                .fontWeight(.semibold)
                            Text(
                                "1 \(rate.baseCurrency.value) = \(NSDecimalNumber(decimal: rate.rate).stringValue) \(rate.quoteCurrency.value)"
                            )
                            .font(.subheadline.monospacedDigit())
                            Text(
                                String(
                                    format: String(localized: "fx.effective_day_format"),
                                    rate.effectiveContext.dayKey,
                                    rate.effectiveContext.timeZoneIdentifier
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDeletionID = rate.id
                                isConfirmingDeletion = true
                            } label: {
                                Label("action.delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("fx.saved_rates")
            } footer: {
                Text("fx.estimated_detail")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("fx.title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let base = model.profile?.baseCurrency.value { baseCode = base }
        }
        .confirmationDialog(
            "fx.delete_title",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("action.delete", role: .destructive) {
                guard let id = pendingDeletionID else { return }
                Task { await delete(id) }
            }
            Button("action.cancel", role: .cancel) { pendingDeletionID = nil }
        } message: {
            Text("fx.delete_detail")
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private func save() async {
        guard let base = try? CurrencyCode(baseCode),
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
            rateText = ""
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func delete(_ id: UUID) async {
        do {
            try await model.deleteExchangeRate(id: id)
            pendingDeletionID = nil
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
