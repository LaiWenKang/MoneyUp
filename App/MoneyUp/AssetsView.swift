import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

struct AssetsView: View {
    @Environment(AppModel.self) private var model
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
                    Text("assets.account_net_worth_note")
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
                                                        format: String(localized: "fx.snapshot_evidence_format"),
                                                        formattedMoney(evidence.source),
                                                        NSDecimalNumber(decimal: evidence.appliedRate).stringValue,
                                                        formattedMoney(evidence.converted)
                                                    )
                                                )
                                                .font(.caption.monospacedDigit())
                                                Text(
                                                    String(
                                                        format: String(localized: "fx.snapshot_rate_day_format"),
                                                        evidence.effectiveDayKey,
                                                        evidence.usedInverseRate
                                                            ? String(localized: "fx.snapshot_inverse")
                                                            : String(localized: "fx.snapshot_direct")
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

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("tab.assets")
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

private struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var type: FinancialAccountType = .bank
    @State private var currencyCode = SupportedCurrencies.regionalDefault
    @State private var startingBalanceText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var startingBalance: Decimal? {
        parsedOpeningBalance(from: startingBalanceText, accountType: type)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("account.name", text: $name)
                    Picker("account.type", selection: $type) {
                        ForEach(FinancialAccountType.allCases, id: \.self) { item in
                            Label(item.localizedTitle, systemImage: item.systemImage)
                                .tag(item)
                        }
                    }
                } header: {
                    Text("account.details_title")
                } footer: {
                    Text("account.details_help")
                }

                Section {
                    SearchableCurrencyPicker(
                        title: "account.currency",
                        selection: $currencyCode,
                        existing: model.accounts.compactMap(\.currency)
                    )
                    TextField(type.openingBalanceLabel, text: $startingBalanceText)
                        .moneyAmountKeyboard(
                            currency: try? CurrencyCode(currencyCode),
                            allowsNegative: !type.isLiabilityAccount
                        )
                } header: {
                    Text("account.opening_title")
                } footer: {
                    Text(type.openingBalanceGuidance)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("account.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                currencyCode = model.profile?.baseCurrency.value ?? "SGD"
            }
            .onChange(of: type) { _, _ in
                errorMessage = nil
            }
        }
    }

    private func save() async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = String(localized: "account.name_error")
            return
        }
        guard let startingBalance else {
            errorMessage = type.isLiabilityAccount
                ? String(localized: "account.amount_owed_error")
                : String(localized: "account.current_balance_error")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.addAccount(
                name: name,
                type: type,
                currencyCode: currencyCode,
                startingBalance: startingBalance
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct AccountManagementSheet: View {
    private enum PendingLifecycleAction {
        case archive
        case restore
        case merge
        case deleteWithReassignment
        case deleteUnused
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let account: LedgerAccount

    @State private var name: String
    @State private var balanceText: String
    @State private var targetID: UUID?
    @State private var pendingLifecycleAction: PendingLifecycleAction?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(account: LedgerAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _balanceText = State(initialValue: "")
    }

    private var currentAccount: LedgerAccount {
        model.accounts.first { $0.id == account.id } ?? account
    }

    private var targets: [LedgerAccount] {
        model.compatibleLifecycleTargets(for: account.id)
    }

    private var impact: AppModel.LedgerItemLifecycleImpact {
        model.lifecycleImpact(for: account.id)
    }

    private var editedBalance: Decimal? {
        guard let value = decimalAmount(from: balanceText) else { return nil }
        guard currentAccount.kind != .liability || value >= .zero else { return nil }
        return value
    }

    private var balanceLabel: LocalizedStringKey {
        currentAccount.kind == .liability ? "account.amount_owed" : "account.current_balance"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("lifecycle.name") {
                    TextField("account.name", text: $name)
                }
                Section {
                    TextField(balanceLabel, text: $balanceText)
                        .moneyAmountKeyboard(
                            currency: currentAccount.currency,
                            allowsNegative: currentAccount.kind != .liability
                        )
                        .disabled(currentAccount.isArchived)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if currentAccount.kind == .liability {
                            Text("account.amount_owed_detail")
                        } else if currentAccount.accountType == .brokerage
                            || currentAccount.accountType == .investment {
                            Text("account.investment_cash_detail")
                        } else {
                            Text("account.current_balance_detail")
                        }
                        Text("account.adjustment_detail")
                    }
                }

                Section {
                    Button {
                        pendingLifecycleAction = currentAccount.isArchived
                            ? .restore : .archive
                    } label: {
                        Label {
                            Text(
                                currentAccount.isArchived
                                    ? LocalizedStringKey("lifecycle.restore")
                                    : LocalizedStringKey("lifecycle.archive")
                            )
                        } icon: {
                            Image(
                                systemName: currentAccount.isArchived
                                    ? "arrow.uturn.backward.circle" : "archivebox"
                            )
                        }
                    }

                    if !targets.isEmpty {
                        Picker("lifecycle.destination", selection: $targetID) {
                            ForEach(targets) { target in
                                Text(target.name).tag(Optional(target.id))
                            }
                        }

                        Button {
                            pendingLifecycleAction = .merge
                        } label: {
                            Label("lifecycle.merge", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(targetID == nil)

                        Button(role: .destructive) {
                            pendingLifecycleAction = .deleteWithReassignment
                        } label: {
                            Label(
                                "lifecycle.delete_reassign",
                                systemImage: "trash.slash"
                            )
                        }
                        .disabled(targetID == nil)
                    }

                    if impact.isUnused {
                        Button(role: .destructive) {
                            pendingLifecycleAction = .deleteUnused
                        } label: {
                            Label("lifecycle.delete_unused", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("lifecycle.manage")
                } footer: {
                    Text(impactSummary(impact))
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(currentAccount.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                guard balanceText.isEmpty else { return }
                targetID = targets.first?.id
                switch model.displayBalanceResult(for: currentAccount) {
                case let .available(balance):
                    balanceText = editableAmount(balance.amount)
                case let .unavailable(issue):
                    errorMessage = issue.localizedDescription
                }
            }
            .confirmationDialog(
                "lifecycle.confirm_title",
                isPresented: Binding(
                    get: { pendingLifecycleAction != nil },
                    set: { if !$0 { pendingLifecycleAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(confirmButtonTitle, role: confirmButtonRole) {
                    Task { await performLifecycleAction() }
                }
                Button("action.cancel", role: .cancel) {
                    pendingLifecycleAction = nil
                }
            } message: {
                Text(confirmMessage)
            }
        }
    }

    private func save() async {
        guard let balance = editedBalance else {
            errorMessage = currentAccount.kind == .liability
                ? String(localized: "account.amount_owed_error")
                : String(localized: "account.current_balance_error")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.renameLedgerItem(id: account.id, name: name)
            if !currentAccount.isArchived {
                try await model.setAccountBalance(
                    accountID: account.id,
                    displayBalance: balance
                )
            }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private var confirmButtonTitle: LocalizedStringKey {
        switch pendingLifecycleAction {
        case .archive: "lifecycle.archive"
        case .restore: "lifecycle.restore"
        case .merge: "lifecycle.merge"
        case .deleteWithReassignment: "lifecycle.delete_reassign"
        case .deleteUnused: "lifecycle.delete_unused"
        case nil: "action.okay"
        }
    }

    private var confirmButtonRole: ButtonRole? {
        switch pendingLifecycleAction {
        case .deleteWithReassignment, .deleteUnused: .destructive
        default: nil
        }
    }

    private var confirmMessage: String {
        let base = impactSummary(impact)
        switch pendingLifecycleAction {
        case .archive:
            return String(localized: "lifecycle.confirm_archive") + " " + base
        case .restore:
            return String(localized: "lifecycle.confirm_restore")
        case .merge:
            return String(localized: "lifecycle.confirm_merge") + " " + base
        case .deleteWithReassignment:
            return String(localized: "lifecycle.confirm_reassign") + " " + base
        case .deleteUnused:
            return String(localized: "lifecycle.confirm_delete")
        case nil:
            return ""
        }
    }

    private func performLifecycleAction() async {
        let action = pendingLifecycleAction
        pendingLifecycleAction = nil
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            switch action {
            case .archive:
                try await model.setLedgerItemArchived(id: account.id, isArchived: true)
            case .restore:
                try await model.setLedgerItemArchived(id: account.id, isArchived: false)
            case .merge:
                guard let targetID else { return }
                try await model.mergeLedgerItem(id: account.id, into: targetID)
                dismiss()
            case .deleteWithReassignment:
                guard let targetID else { return }
                try await model.deleteLedgerItem(
                    id: account.id,
                    reassigningTo: targetID
                )
                dismiss()
            case .deleteUnused:
                try await model.deleteLedgerItem(id: account.id)
                dismiss()
            case nil:
                return
            }
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct AddHoldingSheet: View {
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

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
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

private struct HoldingManagementSheet: View {
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
                                            format: String(localized: "holding.realized_format"),
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
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
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
                    format: String(localized: "holding.realized_format"),
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
