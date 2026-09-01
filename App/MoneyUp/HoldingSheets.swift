import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

struct AddHoldingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let accounts: [LedgerAccount]

    @State private var accountID: UUID?
    @State private var symbol = ""
    @State private var name = ""
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var currencyCode = SupportedCurrencies.regionalDefault
    @State private var openingTreatment: AppModel.InvestmentOpeningTreatment?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        accountID != nil
            && openingTreatment != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (decimalAmount(from: quantityText) ?? .zero) > .zero
            && (decimalAmount(from: priceText) ?? .zero) > .zero
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("transaction.account", selection: $accountID) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                TextField("holding.symbol", text: $symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("holding.name", text: $name)
                TextField("holding.quantity", text: $quantityText)
                    .keyboardType(.decimalPad)
                TextField("holding.price", text: $priceText)
                    .moneyAmountKeyboard(currency: try? CurrencyCode(currencyCode))
                SearchableCurrencyPicker(
                    title: "account.currency",
                    selection: $currencyCode,
                    existing: model.accounts.compactMap(\.currency)
                )

                Section {
                    Button {
                        openingTreatment = .deductFromCash
                    } label: {
                        treatmentRow(
                            title: "holding.opening_deduct_title",
                            detail: "holding.opening_deduct_detail",
                            selected: openingTreatment == .deductFromCash
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        openingTreatment = .cashAlreadyExcludesPosition
                    } label: {
                        treatmentRow(
                            title: "holding.opening_existing_title",
                            detail: "holding.opening_existing_detail",
                            selected: openingTreatment == .cashAlreadyExcludesPosition
                        )
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("holding.opening_treatment")
                } footer: {
                    Text("holding.opening_treatment_help")
                }

            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("holding.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                accountID = accounts.first?.id
                currencyCode = accounts.first?.currency?.value
                    ?? model.profile?.baseCurrency.value ?? "SGD"
            }
            .onChange(of: accountID) { _, newValue in
                if let code = accounts.first(where: { $0.id == newValue })?.currency?.value {
                    currencyCode = code
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func save() async {
        guard let accountID,
              let openingTreatment,
              let quantity = decimalAmount(from: quantityText),
              let price = decimalAmount(from: priceText) else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let holding = try InvestmentHolding(
                accountID: accountID,
                symbol: symbol,
                name: name,
                quantity: quantity,
                price: try Money(price, currency: CurrencyCode(currencyCode)),
                priceAsOf: Date()
            )
            try await model.addInvestmentHolding(
                holding,
                treatment: openingTreatment
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func treatmentRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        selected: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct HoldingManagementSheet: View {
    private enum Action: String, CaseIterable, Identifiable {
        case reprice
        case buy
        case sell
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .reprice: "holding.reprice"
            case .buy: "holding.buy"
            case .sell: "holding.sell"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let holdingID: UUID
    @State private var action: Action = .reprice
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var asOf = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var migrationChoicePresented = false
    @State private var migrationAccountID: UUID?

    private var holding: InvestmentHolding? {
        model.investmentHoldings.first { $0.id == holdingID }
    }

    private var migrationAccounts: [LedgerAccount] {
        guard let currency = holding?.price?.currency else { return [] }
        return model.userAccounts.filter {
            ($0.accountType == .investment || $0.accountType == .brokerage)
                && $0.currency == currency
        }
    }

    private var activityDateRange: ClosedRange<Date> {
        let now = Date()
        let lowerBound = min(holding?.latestActivityDate ?? Date.distantPast, now)
        return lowerBound...now
    }

    var body: some View {
        NavigationStack {
            Form {
                if let holding {
                    Section {
                        LabeledContent("holding.quantity") {
                            Text(holding.quantity, format: .number.precision(.fractionLength(0...6)))
                        }
                        if let price = holding.price {
                            LabeledContent("holding.price", value: formattedMoney(price))
                        }
                        if let date = holding.priceAsOf {
                            LabeledContent("holding.price_as_of") {
                                HStack {
                                    Text(date, format: .dateTime.year().month().day())
                                    if holding.isPriceStale(
                                        relativeTo: Date(),
                                        calendar: model.reportingCalendar
                                    ) {
                                        Text("holding.stale").foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }

                    if holding.isArchived {
                        Section {
                            Label("holding.archived_detail", systemImage: "archivebox.fill")
                                .foregroundStyle(.secondary)
                        }
                    } else if holding.needsLedgerConnection {
                        Section {
                            Text("holding.migration_explanation")
                                .font(.subheadline)
                            if !migrationAccounts.isEmpty {
                                Picker("holding.cash_account", selection: $migrationAccountID) {
                                    ForEach(migrationAccounts) { account in
                                        Text(account.name).tag(Optional(account.id))
                                    }
                                }
                            } else {
                                Text("holding.add_matching_account")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("holding.connect_ledger") {
                                migrationChoicePresented = true
                            }
                            .disabled(migrationAccountID == nil)
                        } footer: {
                            Text("holding.migration_review_detail")
                        }
                    } else {
                        Section {
                            Picker("holding.action", selection: $action) {
                                ForEach(Action.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            if action != .reprice {
                                TextField("holding.quantity", text: $quantityText)
                                    .keyboardType(.decimalPad)
                            }
                            TextField("holding.unit_price", text: $priceText)
                                .keyboardType(.decimalPad)
                            DatePicker(
                                "holding.price_as_of",
                                selection: $asOf,
                                in: activityDateRange,
                                displayedComponents: .date
                            )
                            Button("action.save") { Task { await save() } }
                                .disabled(isSaving || (decimalAmount(from: priceText) ?? .zero) <= .zero)
                        } footer: {
                            Text("holding.fifo_disclaimer")
                        }
                    }

                    if !holding.lots.isEmpty {
                        Section("holding.open_lots") {
                            ForEach(holding.lots.filter { $0.remainingQuantity > .zero }) { lot in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lot.acquiredAt, format: .dateTime.year().month().day())
                                    Text("\(NSDecimalNumber(decimal: lot.remainingQuantity).stringValue) × \(formattedMoney(lot.unitCost))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !holding.disposals.isEmpty {
                        Section("holding.realized_history") {
                            ForEach(holding.disposals.reversed()) { disposal in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(disposal.occurredAt, format: .dateTime.year().month().day())
                                    Text(
                                        String(
                                            format: AppLocalization.string("holding.realized_format"),
                                            formattedMoney(disposal.realizedGainLoss)
                                        )
                                    )
                                    .font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                }
                if let resultMessage { Section { Text(resultMessage).foregroundStyle(.green) } }
            }
            .navigationTitle(holding?.symbol.isEmpty == false ? holding?.symbol ?? "" : holding?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.done") { dismiss() }
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                if let price = holding?.price { priceText = editableAmount(price.amount) }
                migrationAccountID = migrationAccounts.first(where: {
                    $0.id == holding?.accountID
                })?.id ?? migrationAccounts.first?.id
            }
            .confirmationDialog(
                "holding.connect_ledger",
                isPresented: $migrationChoicePresented,
                titleVisibility: .visible
            ) {
                Button("holding.cash_includes_position") {
                    Task { await migrate(deductFromCash: true) }
                }
                Button("holding.cash_excludes_position") {
                    Task { await migrate(deductFromCash: false) }
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("holding.migration_choice_detail")
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func save() async {
        guard let price = decimalAmount(from: priceText) else { return }
        let quantity = decimalAmount(from: quantityText) ?? .zero
        isSaving = true
        errorMessage = nil
        resultMessage = nil
        defer { isSaving = false }
        do {
            switch action {
            case .reprice:
                try await model.repriceInvestmentHolding(id: holdingID, unitPrice: price, asOf: asOf)
            case .buy:
                try await model.recordInvestmentPurchase(
                    holdingID: holdingID,
                    quantity: quantity,
                    unitPrice: price,
                    occurredAt: asOf
                )
            case .sell:
                let result = try await model.recordInvestmentSale(
                    holdingID: holdingID,
                    quantity: quantity,
                    unitPrice: price,
                    occurredAt: asOf
                )
                resultMessage = String(
                    format: AppLocalization.string("holding.realized_format"),
                    formattedMoney(result.realizedGainLoss)
                )
            }
            quantityText = ""
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func migrate(deductFromCash: Bool) async {
        do {
            try await model.connectLegacyInvestmentHolding(
                id: holdingID,
                fundingAccountID: migrationAccountID,
                deductFromCash: deductFromCash
            )
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
