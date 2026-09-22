import Foundation
import MoneyUpCore
import SwiftUI

/// The currency beside the amount is a control, not a caption. It switches
/// the paying account (money always leaves an account in that account's
/// currency) or converts an amount paid in another currency at the rate the
/// user was actually charged, keeping the original figure in the note.
extension QuickLogEntryView {
    @ViewBuilder
    var amountCurrencyControl: some View {
        if let currency = selectedAccountCurrency {
            Menu {
                ForEach(currencyChoices, id: \.currency) { choice in
                    if choice.accounts.count == 1, let account = choice.accounts.first {
                        Button {
                            selectPayingAccount(account)
                        } label: {
                            Label(
                                "\(choice.currency.value) · \(account.name)",
                                systemImage: choice.currency == currency ? "checkmark" : "banknote"
                            )
                        }
                    } else {
                        Menu {
                            ForEach(choice.accounts) { account in
                                Button(account.name) { selectPayingAccount(account) }
                            }
                        } label: {
                            Label(choice.currency.value, systemImage: choice.currency == currency ? "checkmark" : "banknote")
                        }
                    }
                }
                if kind != .transfer {
                    Divider()
                    Button {
                        isConvertingCurrency = true
                    } label: {
                        Label("fx.convert.menu", systemImage: "arrow.left.arrow.right.circle")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(currency.value)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("transaction.currency")
            .accessibilityValue(Text(currency.value))
            .accessibilityHint("fx.convert.currency_hint")
            .accessibilityIdentifier("quick-log-currency")
        }
    }

    struct CurrencyChoice {
        let currency: CurrencyCode
        let accounts: [LedgerAccount]
    }

    var currencyChoices: [CurrencyChoice] {
        var byCurrency: [CurrencyCode: [LedgerAccount]] = [:]
        for account in sourceAccounts {
            guard let currency = account.currency else { continue }
            byCurrency[currency, default: []].append(account)
        }
        return byCurrency.keys.sorted { $0.value < $1.value }.map {
            CurrencyChoice(currency: $0, accounts: byCurrency[$0] ?? [])
        }
    }

    func selectPayingAccount(_ account: LedgerAccount) {
        guard account.id != accountID else { return }
        cancelSmartParsing()
        cancelOnDeviceAssistance()
        smartState.edited(.account)
        receiptProtectedFields.insert(\.accountID)
        accountID = account.id
        accountWasEdited = true
        autoAppliedAccountSuggestionID = nil
        invalidateCaptureSuggestions(preservingAccount: true)
        persistUserDraftChange { $0.accountID = account.id }
    }

    @ViewBuilder
    var currencyConversionSheet: some View {
        if let destination = selectedAccountCurrency {
            QuickLogCurrencyConversionSheet(
                destination: destination,
                candidates: conversionCurrencyCandidates(excluding: destination),
                occurredAt: occurredAt,
                savedRate: { source, amount in
                    try? model.historicalConversion(
                        amount: amount, from: source, to: destination, occurredAt: occurredAt
                    )
                }
            ) { result in
                guard selectedAccountCurrency == destination else { return }
                cancelSmartParsing()
                cancelOnDeviceAssistance()
                smartState.edited(.amount)
                receiptProtectedFields.insert(\.amountText)
                amountText = editableAmount(result.converted.amount)
                let memo = String(
                    format: AppLocalization.string("fx.convert.note_format"),
                    result.source.currency.value,
                    editableAmount(result.source.amount),
                    editableAmount(result.rate)
                )
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                note = trimmed.isEmpty ? memo : trimmed + " · " + memo
                persistUserDraftChange { snapshot in
                    snapshot.amountText = amountText
                    snapshot.note = note
                }
                focusedField = nil
            }
        }
    }

    private func conversionCurrencyCandidates(excluding destination: CurrencyCode) -> [CurrencyCode] {
        var currencies = Set(model.accounts.compactMap(\.currency))
        if let base = model.profile?.baseCurrency { currencies.insert(base) }
        for rate in model.exchangeRates {
            currencies.insert(rate.baseCurrency)
            currencies.insert(rate.quoteCurrency)
        }
        currencies.remove(destination)
        return currencies.sorted { $0.value < $1.value }
    }
}

struct QuickLogCurrencyConversionResult: Equatable {
    let source: Money
    let converted: Money
    let rate: Decimal
}

/// Paid-in-another-currency helper: the account still moves by exactly what
/// it was charged, and the original amount plus rate travel in the note.
struct QuickLogCurrencyConversionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let destination: CurrencyCode
    let candidates: [CurrencyCode]
    let occurredAt: Date
    let savedRate: (CurrencyCode, Decimal) -> HistoricalCurrencyConversion?
    let apply: (QuickLogCurrencyConversionResult) -> Void

    @State private var sourceCode: String = ""
    @State private var customCode: String = ""
    @State private var amountText = ""
    @State private var rateText = ""
    @State private var didPrefillRate = false

    private var sourceCurrency: CurrencyCode? {
        try? CurrencyCode(sourceCode.isEmpty ? customCode : sourceCode)
    }

    private var result: QuickLogCurrencyConversionResult? {
        guard let source = sourceCurrency, source != destination,
              let amount = decimalAmount(from: amountText), amount > .zero,
              let rate = decimalAmount(from: rateText), rate > .zero,
              let money = try? Money(amount, currency: source),
              let converted = try? ManualCurrencyConversion.convert(
                  source: money, to: destination, rate: rate, inverse: false
              ) else { return nil }
        return QuickLogCurrencyConversionResult(source: money, converted: converted, rate: rate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $sourceCode) {
                        ForEach(candidates, id: \.value) { currency in
                            Text(currency.value).tag(currency.value)
                        }
                        Text("fx.convert.other_currency").tag("")
                    } label: {
                        Label("fx.convert.paid_in", systemImage: "globe")
                    }
                    if sourceCode.isEmpty {
                        TextField("fx.convert.currency_code", text: $customCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Label("quick_log.amount", systemImage: "number")
                        Spacer()
                        TextField("", text: $amountText, prompt: Text(verbatim: "0.00"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("quick-log-convert-amount")
                    }
                    HStack {
                        Label("fx.convert.rate", systemImage: "arrow.left.arrow.right")
                        Spacer()
                        TextField("", text: $rateText, prompt: Text(verbatim: "1.0000"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("quick-log-convert-rate")
                    }
                } header: {
                    MoneyUpSectionHeader("fx.convert.title", explanation: "fx.convert.detail")
                } footer: {
                    if let source = sourceCurrency {
                        Text("1 \(source.value) = \(rateText.isEmpty ? "…" : rateText) \(destination.value)")
                            .monospacedDigit()
                    }
                }
                Section {
                    if let result {
                        HStack(alignment: .firstTextBaseline) {
                            Text("fx.convert.charged")
                            Spacer()
                            Text("\(destination.value) \(editableAmount(result.converted.amount))")
                                .font(.title3.weight(.semibold).monospacedDigit())
                        }
                        Button {
                            apply(result)
                            dismiss()
                        } label: {
                            Label("fx.convert.apply", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.moneyUpAction)
                        .accessibilityIdentifier("quick-log-convert-apply")
                    } else {
                        MoneyUpStatePlaceholder(
                            systemImage: "arrow.left.arrow.right.circle",
                            tint: .secondary,
                            title: "fx.convert.waiting"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { MoneyUpBackdrop() }
            .navigationTitle("fx.convert.title")
            .navigationBarTitleDisplayMode(.inline)
            .moneyUpNavigationSurface()
            .toolbar { MoneyUpKeyboardDoneToolbar() }
            .onAppear {
                if sourceCode.isEmpty, let first = candidates.first { sourceCode = first.value }
            }
            .onChange(of: sourceCode) { _, _ in didPrefillRate = false; prefillRate() }
            .onChange(of: amountText) { _, _ in prefillRate() }
            .moneyUpProtectDraft(hasChanges: !amountText.isEmpty || !rateText.isEmpty, isSaving: false)
        }
    }

    /// A saved historical rate for the entry's day is offered once; the
    /// user's own typed rate always wins.
    private func prefillRate() {
        guard !didPrefillRate, rateText.isEmpty, let source = sourceCurrency,
              let amount = decimalAmount(from: amountText), amount > .zero,
              let conversion = savedRate(source, amount) else { return }
        didPrefillRate = true
        rateText = editableAmount(conversion.appliedRate)
    }
}
