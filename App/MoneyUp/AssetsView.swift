import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

struct AssetsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MoneyAmountPrivacy.storageKey)
    private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var isAddingAccount = false
    @State private var isAddingHolding = false
    @State private var editingAccount: LedgerAccount?
    @State private var editingHolding: InvestmentHolding?
    @State private var isConfirmingExport = false
    @State private var isExporting = false
    @State private var exportDocument = CSVDocument(text: "")
    @State private var isExportingXLSX = false
    @State private var xlsxDocument = XLSXDocument()
    @State private var errorMessage: String?
    @State private var holdingPendingDeletion: InvestmentHolding?

    private var investmentAccounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.accountType == .investment || $0.accountType == .brokerage
        }
    }

    private var archivedFinancialAccounts: [LedgerAccount] {
        model.allUserAccounts.filter { $0.isArchived && $0.systemRole == nil }
    }

    private var activeInvestmentHoldings: [InvestmentHolding] {
        model.investmentHoldings.filter { !$0.isArchived }
    }

    private var archivedInvestmentHoldings: [InvestmentHolding] {
        model.investmentHoldings.filter(\.isArchived)
    }

    private var oldestPositionPriceDate: Date? {
        activeInvestmentHoldings
            .filter { $0.positionAccountID != nil && $0.quantity > .zero }
            .compactMap(\.priceAsOf)
            .min()
    }

    private var recordedHoldingsValues: DerivedValue<[Money]> {
        var totals: [CurrencyCode: Decimal] = [:]
        for holding in activeInvestmentHoldings {
            do {
                guard let value = try holding.marketValue() else {
                    DerivedValueDiagnostics.record(
                        .holdingValuationFailed,
                        operation: "assets-recorded-holdings-missing-price"
                    )
                    return .unavailable(.holdingValuationFailed)
                }
                totals[value.currency] = try CheckedDecimal.adding(
                    totals[value.currency] ?? .zero,
                    value.amount
                )
            } catch let error as DecimalCalculationError {
                DerivedValueDiagnostics.record(
                    .amountCalculationFailed,
                    operation: "assets-recorded-holdings-overflow",
                    error: error
                )
                return .unavailable(.amountCalculationFailed)
            } catch {
                DerivedValueDiagnostics.record(
                    .holdingValuationFailed,
                    operation: "assets-recorded-holdings",
                    error: error
                )
                return .unavailable(.holdingValuationFailed)
            }
        }
        do {
            return .available(try totals.sorted { $0.key < $1.key }.map {
                try Money($0.value, currency: $0.key)
            })
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }

    private func value(for holding: InvestmentHolding) -> DerivedValue<Money> {
        do {
            guard let value = try holding.marketValue() else {
                DerivedValueDiagnostics.record(
                    .holdingValuationFailed,
                    operation: "assets-holding-row-missing-price"
                )
                return .unavailable(.holdingValuationFailed)
            }
            return .available(value)
        } catch {
            DerivedValueDiagnostics.record(
                .holdingValuationFailed,
                operation: "assets-holding-row",
                error: error
            )
            return .unavailable(.holdingValuationFailed)
        }
    }

    var body: some View {
        let _ = hidesAmounts
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("assets.account_net_worth")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        switch model.netWorthByCurrencyResult() {
                        case let .available(amounts):
                            ForEach(amounts, id: \.currency) { netWorth in
                                Text(formattedMoney(netWorth))
                                    .font(.title.bold().monospacedDigit())
                            }
                            switch model.estimatedNetWorthResult() {
                            case let .available(estimate):
                                if let estimate {
                                    let conversionDate = estimate.conversionAsOf
                                        .formattedForReporting(
                                            .dateTime.year().month().day(),
                                            calendar: model.reportingCalendar
                                        )
                                    HStack(spacing: 4) {
                                        Text("≈ \(formattedMoney(estimate.total))")
                                            .font(.headline.monospacedDigit())
                                        Text("·")
                                        Text("fx.rates_as_of")
                                        Text(conversionDate)
                                    }
                                    .foregroundStyle(.secondary)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("fx.net_worth_estimated")
                                    .accessibilityValue(
                                        "\(formattedMoney(estimate.total)), \(conversionDate)"
                                    )
                                } else if amounts.filter({ !$0.isZero }).count > 1 {
                                    Text("fx.net_worth_complete_rate_needed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            case let .unavailable(issue):
                                DerivedValueUnavailableView(issue: issue)
                            }
                        case let .unavailable(issue):
                            DerivedValueUnavailableView(
                                issue: issue,
                                prominent: true
                            )
                        }
                        if let oldestPositionPriceDate {
                            HStack(spacing: 4) {
                                Text("assets.oldest_position_price")
                                Text(
                                    oldestPositionPriceDate,
                                    format: .dateTime.year().month().day()
                                )
                                if model.investmentHoldings.contains(where: {
                                    $0.positionAccountID != nil
                                        && $0.quantity > .zero
                                        && $0.isPriceStale(
                                            relativeTo: Date(),
                                            calendar: model.reportingCalendar
                                        )
                                }) {
                                    Text("holding.stale").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Button("assets.capture_snapshot") {
                            Task {
                                do { try await model.captureNetWorthSnapshot() }
                                catch {
                                    errorMessage = safeUserMessage(
                                        for: error,
                                        context: .save
                                    )
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 8)
                } footer: {
                    MoneyUpExplainer("assets.account_net_worth_note")
                }

                Section("assets.accounts") {
                    ForEach(model.userAccounts) { account in
                        Button {
                            editingAccount = account
                        } label: {
                            HStack(spacing: 12) {
                                MoneyUpSymbolBadge(
                                    systemImage: account.accountType?.systemImage
                                        ?? "wallet.bifold"
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    Text(account.currency?.value ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                switch model.displayBalanceResult(for: account) {
                                case let .available(balance):
                                    Text(formattedMoney(balance))
                                        .font(.subheadline.monospacedDigit())
                                case let .unavailable(issue):
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("—")
                                            .font(.subheadline.monospacedDigit())
                                        Text(issue.localizedDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        isAddingAccount = true
                    } label: {
                        Label("account.add", systemImage: "plus.circle")
                    }
                }

                Section {
                    NavigationLink {
                        LoanCenterView()
                    } label: {
                        Label("loan.title", systemImage: "car.side.fill")
                    }
                } footer: {
                    MoneyUpExplainer("loan.assets_detail")
                }

                if !archivedFinancialAccounts.isEmpty {
                    Section("lifecycle.archived") {
                        ForEach(archivedFinancialAccounts) { account in
                            Button {
                                editingAccount = account
                            } label: {
                                HStack {
                                    Label(account.name, systemImage: "archivebox.fill")
                                    Spacer()
                                    Text(account.currency?.value ?? "")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("assets.investments") {
                    if case let .available(values) = recordedHoldingsValues {
                        ForEach(values.filter { !$0.isZero }, id: \.currency) { value in
                            LabeledContent(
                                "assets.recorded_holdings",
                                value: formattedMoney(value)
                            )
                        }
                    } else if case let .unavailable(issue) = recordedHoldingsValues {
                        DerivedValueUnavailableView(issue: issue)
                    }
                    if activeInvestmentHoldings.isEmpty {
                        VStack(spacing: 8) {
                            MoneyUpIllustration("MoneyUpMoneyWorld", role: .inline)
                            Text("assets.no_holdings")
                                .font(.headline)
                            Text("assets.no_holdings_detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    } else {
                        ForEach(activeInvestmentHoldings) { holding in
                            Button {
                                editingHolding = holding
                            } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(holding.symbol.isEmpty ? holding.name : holding.symbol)
                                        .fontWeight(.semibold)
                                    Text(holding.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if holding.needsLedgerConnection {
                                        Label("holding.needs_ledger", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else if let priceAsOf = holding.priceAsOf {
                                        HStack(spacing: 4) {
                                            Text("holding.price_as_of")
                                            Text(priceAsOf, format: .dateTime.year().month().day())
                                            if holding.isPriceStale(
                                                relativeTo: Date(),
                                                calendar: model.reportingCalendar
                                            ) {
                                                Text("holding.stale")
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    switch value(for: holding) {
                                    case let .available(value):
                                        Text(formattedMoney(value))
                                            .font(.subheadline.monospacedDigit())
                                    case let .unavailable(issue):
                                        Text("—")
                                            .font(.subheadline.monospacedDigit())
                                        Text(issue.localizedDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text(
                                        holding.quantity,
                                        format: .number.precision(.fractionLength(0...6))
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    holdingPendingDeletion = holding
                                } label: {
                                    Label("action.delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        isAddingHolding = true
                    } label: {
                        Label("holding.add", systemImage: "plus.circle")
                    }
                    .disabled(investmentAccounts.isEmpty)

                    if investmentAccounts.isEmpty {
                        Text("holding.add_investment_account_first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !archivedInvestmentHoldings.isEmpty {
                    Section("holding.archived") {
                        ForEach(archivedInvestmentHoldings) { holding in
                            Button {
                                editingHolding = holding
                            } label: {
                                HStack {
                                    Label(
                                        holding.symbol.isEmpty
                                            ? holding.name
                                            : holding.symbol,
                                        systemImage: "archivebox.fill"
                                    )
                                    Spacer()
                                    Text(holding.price?.currency.value ?? "")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !model.netWorthSnapshots.isEmpty {
                    Section("assets.net_worth_history") {
                        ForEach(model.netWorthSnapshots.prefix(12)) { snapshot in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.capturedAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(snapshot.amounts) { amount in
                                    Text(formattedMoney(amount.money))
                                        .font(.subheadline.monospacedDigit())
                                }
                                if let estimate = snapshot.estimatedBaseTotal,
                                   let asOf = snapshot.conversionAsOf {
                                    HStack(spacing: 4) {
                                        Text("≈ \(formattedMoney(estimate))")
                                            .font(.subheadline.monospacedDigit())
                                        Text("·")
                                        Text("fx.rates_as_of")
                                        Text(asOf, format: .dateTime.year().month().day())
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                if !snapshot.conversionEvidence.isEmpty {
                                    DisclosureGroup("fx.snapshot_conversion_evidence") {
                                        ForEach(snapshot.conversionEvidence) { evidence in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(
                                                    String(
                                                        format: AppLocalization.string("fx.snapshot_evidence_format"),
                                                        formattedMoney(evidence.source),
                                                        NSDecimalNumber(decimal: evidence.appliedRate).stringValue,
                                                        formattedMoney(evidence.converted)
                                                    )
                                                )
                                                .font(.caption.monospacedDigit())
                                                Text(
                                                    String(
                                                        format: AppLocalization.string("fx.snapshot_rate_day_format"),
                                                        evidence.effectiveDayKey,
                                                        evidence.usedInverseRate
                                                            ? AppLocalization.string("fx.snapshot_inverse")
                                                            : AppLocalization.string("fx.snapshot_direct")
                                                    )
                                                )
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                Section("assets.data") {
                    NavigationLink {
                        DataSafetyView()
                    } label: {
                        Label("backup.data_safety", systemImage: "externaldrive.badge.shield.checkmark")
                    }

                    NavigationLink {
                        ExchangeRatesView()
                    } label: {
                        Label("fx.title", systemImage: "arrow.left.arrow.right.circle")
                    }

                    Button {
                        isConfirmingExport = true
                    } label: {
                        Label("export.data", systemImage: "tablecells")
                    }

                    Button {
                        model.lock()
                    } label: {
                        Label("lock.lock_now", systemImage: "lock.fill")
                    }

                    LabeledContent {
                        Text(AppVersion.display).monospacedDigit()
                    } label: {
                        Label("assets.version", systemImage: "info.circle")
                    }

                    NavigationLink {
                        PrivacyAndBetaView()
                    } label: {
                        Label("privacy.title", systemImage: "hand.raised.fill")
                    }
                }

            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("tab.assets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    MoneyUpAmountPrivacyButton()
                }
            }
            .sheet(isPresented: $isAddingAccount) {
                AddAccountSheet()
            }
            .sheet(isPresented: $isAddingHolding) {
                AddHoldingSheet(accounts: investmentAccounts)
            }
            .sheet(item: $editingAccount) { account in
                AccountManagementSheet(account: account)
            }
            .sheet(item: $editingHolding) { holding in
                HoldingManagementSheet(holdingID: holding.id)
            }
            .confirmationDialog(
                "export.warning_title",
                isPresented: $isConfirmingExport,
                titleVisibility: .visible
            ) {
                Button("export.xlsx") {
                    Task {
                        do {
                            xlsxDocument = XLSXDocument(
                                data: try await model.xlsxExport()
                            )
                            isExportingXLSX = true
                        } catch {
                            errorMessage = safeUserMessage(for: error, context: .exportData)
                        }
                    }
                }
                Button("export.csv") {
                    Task {
                        do {
                            exportDocument = CSVDocument(
                                text: try await model.csvExport()
                            )
                            isExporting = true
                        } catch {
                            errorMessage = safeUserMessage(for: error, context: .exportData)
                        }
                    }
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("export.warning_detail")
            }
            .confirmationDialog(
                "holding.delete_title",
                isPresented: Binding(
                    get: { holdingPendingDeletion != nil },
                    set: { if !$0 { holdingPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: holdingPendingDeletion
            ) { holding in
                Button("action.delete", role: .destructive) {
                    holdingPendingDeletion = nil
                    Task { await delete(holding) }
                }
                Button("action.cancel", role: .cancel) {
                    holdingPendingDeletion = nil
                }
            } message: { _ in
                Text("holding.delete_detail")
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "MoneyUp-Ledger"
            ) { result in
                if case let .failure(error) = result {
                    errorMessage = safeUserMessage(for: error, context: .write)
                }
            }
            .fileExporter(
                isPresented: $isExportingXLSX,
                document: xlsxDocument,
                contentType: .officeOpenXMLSpreadsheet,
                defaultFilename: "MoneyUp-Ledger.xlsx"
            ) { result in
                if case let .failure(error) = result {
                    errorMessage = safeUserMessage(for: error, context: .write)
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func delete(_ holding: InvestmentHolding) async {
        do {
            try await model.deleteInvestmentHolding(id: holding.id)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

}
