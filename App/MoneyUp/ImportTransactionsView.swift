import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportTransactionsView: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosingFile = false
    @State private var preview: CSVImportPreview?
    @State private var sourceText = ""
    @State private var inspection: DelimitedImportInspection?
    @State private var columnMapping = CSVColumnMapping()
    @State private var fileName = ""
    @State private var fallbackAccountID: UUID?
    @State private var fallbackExpenseCategoryID: UUID?
    @State private var fallbackIncomeCategoryID: UUID?
    @State private var accountMappings: [String: UUID] = [:]
    @State private var expenseCategoryMappings: [String: UUID] = [:]
    @State private var incomeCategoryMappings: [String: UUID] = [:]
    @State private var defaultCurrencyCode = SupportedCurrencies.regionalDefault
    @State private var isImporting = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var document: ImportDocument?
    @State private var selectedTableID: String?
    @State private var dateEncoding = ImportDateEncoding.text
    @State private var qianjiTypes = false
    @State private var isReading = false
    @State private var readTask: Task<Void, Never>?
    @State private var readID = UUID()
    @State private var typeOverrides: [String: String] = [:]

    private var eligibleAccounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.accountType != .restrictedAllowance
        }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    isChoosingFile = true
                } label: {
                    Label("import.choose_csv", systemImage: "tablecells.badge.ellipsis")
                }
                .disabled(isReading || isImporting)
                if isReading { ProgressView("import.reading") }
                if !fileName.isEmpty {
                    LabeledContent("import.file", value: fileName)
                }
            } header: {
                Text("import.qianji_and_csv")
            } footer: {
                Text("import.local_only_detail")
            }

            if let document, !document.tables.isEmpty {
                Section {
                    Picker("import.table", selection: Binding(get: { selectedTableID }, set: { value in
                        selectedTableID = value
                        selectTable()
                    })) {
                        Text("import.choose_table").tag(Optional<String>.none)
                        ForEach(document.tables) { table in Text(table.name).tag(Optional(table.id)) }
                    }
                    Picker("import.date_encoding", selection: Binding(get: { dateEncoding }, set: { value in
                        dateEncoding = value; preview = nil
                    })) {
                        ForEach(ImportDateEncoding.allCases) { encoding in
                            Text(LocalizedStringKey(encoding.titleKey)).tag(encoding)
                        }
                    }
                    Toggle("import.qianji_type_codes", isOn: Binding(get: { qianjiTypes }, set: { value in
                        qianjiTypes = value; preview = nil
                    }))
                    if !sourceKinds.isEmpty {
                        DisclosureGroup("import.type_mapping") {
                            ForEach(sourceKinds.prefix(32), id: \.self) { source in
                                Picker(selection: Binding(get: { typeOverrides[source] }, set: { value in
                                    typeOverrides[source] = value; preview = nil
                                })) {
                                    Text("import.keep_original_type").tag(Optional<String>.none)
                                    ForEach([ImportedTransactionKind.expense, .income, .transfer, .refund], id: \.rawValue) { kind in
                                        Text(localizedKind(kind)).tag(Optional(kind.rawValue))
                                    }
                                } label: { Text(verbatim: source) }
                            }
                        }
                    }
                } header: {
                    Text("import.tables")
                } footer: {
                    Text("import.structured_detail")
                }
            }

            if let inspection {
                Section {
                    ForEach(CSVImportMappedField.allCases) { field in
                        Picker(
                            localizedField(field),
                            selection: Binding(
                                get: { columnMapping[field] },
                                set: {
                                    columnMapping[field] = $0; preview = nil
                                    if field == .kind { typeOverrides = [:] }
                                    if field == .date { dateEncoding = .text }
                                }
                            )
                        ) {
                            Text("import.column_none").tag(Optional<Int>.none)
                            ForEach(inspection.headers.indices, id: \.self) { index in
                                Text(inspection.headers[index]).tag(Optional(index))
                            }
                        }
                    }
                    Button {
                        applyColumnMapping()
                    } label: {
                        Label("import.apply_mapping", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!columnMapping.hasRequiredColumns)
                } header: {
                    Text("import.column_mapping")
                } footer: {
                    Text("import.column_mapping_detail")
                }

                if !inspection.sampleRows.isEmpty {
                    Section("import.raw_preview") {
                        ForEach(Array(inspection.sampleRows.enumerated()), id: \.offset) { _, row in
                            Text(row.prefix(12).map { String($0.prefix(160)) }.joined(separator: " · "))
                                .font(.caption.monospaced())
                                .lineLimit(2)
                        }
                    }
                }
            }

            if let preview {
                Section {
                    LabeledContent("import.ready", value: "\(preview.rows.count)")
                    LabeledContent("import.needs_review", value: "\(preview.issues.count)")
                    if !preview.issues.isEmpty {
                        DisclosureGroup("import.review_issues") {
                            ForEach(preview.issues.prefix(20)) { issue in
                                Text(
                                    String(
                                        format: AppLocalization.string(
                                            "import.issue_line_format"
                                        ),
                                        issue.line,
                                        localizedIssue(issue.reason)
                                    )
                                )
                                    .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("import.preview")
                } footer: {
                    Text("import.preview_detail")
                }

                Section {
                    SearchableCurrencyPicker(
                        title: "import.default_currency",
                        selection: $defaultCurrencyCode,
                        existing: model.accounts.compactMap(\.currency)
                    )
                    Picker("settings.default_account", selection: $fallbackAccountID) {
                        ForEach(eligibleAccounts) { account in
                            Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                        }
                    }
                    Picker(
                        "settings.default_expense_category",
                        selection: $fallbackExpenseCategoryID
                    ) {
                        ForEach(model.expenseCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    Picker(
                        "settings.default_income_category",
                        selection: $fallbackIncomeCategoryID
                    ) {
                        ForEach(model.incomeCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                } header: {
                    Text("import.fallbacks")
                } footer: {
                    Text("import.fallbacks_detail")
                }

                if !sourceAccountNames(in: preview).isEmpty
                    || !sourceCategoryNames(in: preview, kind: .expense).isEmpty
                    || !sourceCategoryNames(in: preview, kind: .income).isEmpty {
                    Section {
                        ForEach(sourceAccountNames(in: preview), id: \.self) { name in
                            Picker(
                                name,
                                selection: reviewedBinding(
                                    for: name,
                                    in: $accountMappings,
                                    fallback: fallbackAccountID
                                )
                            ) {
                                ForEach(eligibleAccounts) { account in
                                    Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                                }
                            }
                        }
                        ForEach(sourceCategoryNames(in: preview, kind: .expense), id: \.self) { name in
                            Picker(
                                name,
                                selection: reviewedBinding(
                                    for: name,
                                    in: $expenseCategoryMappings,
                                    fallback: fallbackExpenseCategoryID
                                )
                            ) {
                                ForEach(model.expenseCategories) { category in
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                        }
                        ForEach(sourceCategoryNames(in: preview, kind: .income), id: \.self) { name in
                            Picker(
                                name,
                                selection: reviewedBinding(
                                    for: name,
                                    in: $incomeCategoryMappings,
                                    fallback: fallbackIncomeCategoryID
                                )
                            ) {
                                ForEach(model.incomeCategories) { category in
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                        }
                    } header: {
                        Text("import.review_mappings")
                    } footer: {
                        Text("import.review_mappings_detail")
                    }
                }

                Section {
                    ForEach(preview.rows.prefix(10)) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.payee ?? row.categoryName ?? localizedKind(row.kind))
                                    .lineLimit(1)
                                Text(row.occurredAt, format: .dateTime.year().month().day())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                "\(row.currencyCode ?? defaultCurrencyCode) \(NSDecimalNumber(decimal: row.amount).stringValue)"
                            )
                            .font(.subheadline.monospacedDigit())
                        }
                    }
                } header: {
                    Text("import.first_rows")
                }

                Section {
                    Button {
                        Task { await importPreview(preview) }
                    } label: {
                        if isImporting {
                            HStack { ProgressView(); Text("action.working") }
                        } else {
                            Label("import.commit", systemImage: "checkmark.shield.fill")
                        }
                    }
                    .disabled(
                        isImporting
                            || preview.rows.isEmpty
                            || fallbackAccountID == nil
                            || fallbackExpenseCategoryID == nil
                            || fallbackIncomeCategoryID == nil
                    )
                } footer: {
                    Text("import.atomic_detail")
                }
            }

            if let message {
                Section { Label(message, systemImage: "checkmark.circle.fill") }
                    .foregroundStyle(Color.moneyUpPositive)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("import.title")
            .moneyUpNavigationSurface()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selectDefaults() }
        .onDisappear { readTask?.cancel(); readID = UUID(); isReading = false }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: DelimitedImportFile.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileResult(result)
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private func selectDefaults() {
        defaultCurrencyCode = model.profile?.baseCurrency.value ?? "SGD"
        fallbackAccountID = model.profile?.preferredAccountID
            .flatMap { preferred in
                eligibleAccounts.contains(where: { $0.id == preferred }) ? preferred : nil
            } ?? eligibleAccounts.first?.id
        fallbackExpenseCategoryID = model.profile?.preferredExpenseCategoryID
            .flatMap { preferred in
                model.expenseCategories.contains(where: { $0.id == preferred })
                    ? preferred : nil
            } ?? model.expenseCategories.first?.id
        fallbackIncomeCategoryID = model.profile?.preferredIncomeCategoryID
            .flatMap { preferred in
                model.incomeCategories.contains(where: { $0.id == preferred })
                    ? preferred : nil
            } ?? model.incomeCategories.first?.id
    }

    private func handleFileResult(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            readTask?.cancel()
            clearImport()
            readID = UUID()
            let ticket = readID
            isReading = true
            readTask = Task {
                let worker = Task.detached(priority: .userInitiated) { try ImportDocument.decode(DelimitedImportFile.readData(url)) }
                do {
                    let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, ticket == readID else { return }
                    document = loaded
                    selectedTableID = loaded.tables.count == 1 ? loaded.tables.first?.id : nil
                    dateEncoding = .text
                    qianjiTypes = false
                    typeOverrides = [:]
                    fileName = url.lastPathComponent
                    selectTable()
                } catch {
                    guard !Task.isCancelled, ticket == readID else { return }
                    clearImport()
                    errorMessage = safeUserMessage(for: error, context: .read)
                }
                if ticket == readID { isReading = false }
            }
        } catch {
            if (error as? CocoaError)?.code != .userCancelled {
                errorMessage = safeUserMessage(for: error, context: .read)
            }
        }
    }

    private func selectTable() {
        do {
            dateEncoding = .text; qianjiTypes = false; typeOverrides = [:]
            preview = nil
            inspection = nil
            sourceText = try selectedTable?.csv() ?? ""
            guard !sourceText.isEmpty else { return }
            inspection = try TransactionCSVImporter.inspect(sourceText)
            columnMapping = inspection?.suggestedMapping ?? CSVColumnMapping()
            if columnMapping.hasRequiredColumns {
                preview = try TransactionCSVImporter.parse(
                    sourceText,
                    mapping: columnMapping,
                    timeZone: model.reportingCalendar.timeZone
                )
                prepareReviewedMappings(for: preview)
            } else {
                preview = nil
            }
            message = nil
            errorMessage = nil
        } catch {
            clearImport()
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }

    private var selectedTable: ImportDataTable? { document?.tables.first { $0.id == selectedTableID } }
    private var sourceKinds: [String] {
        guard let table = selectedTable, let column = columnMapping[.kind] else { return [] }
        return Set(table.rows.dropFirst().compactMap { row in
            row.indices.contains(column) ? row[column].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }).filter { !$0.isEmpty }.sorted()
    }

    private func clearImport() {
        preview = nil; inspection = nil; sourceText = ""; fileName = ""
        document = nil; selectedTableID = nil
    }

    private func applyColumnMapping() {
        do {
            preview = try TransactionCSVImporter.parse(
                try selectedTable?.csv(mapping: columnMapping, dateEncoding: dateEncoding,
                                       qianjiTypes: qianjiTypes, typeOverrides: typeOverrides) ?? sourceText,
                mapping: columnMapping,
                timeZone: model.reportingCalendar.timeZone
            )
            prepareReviewedMappings(for: preview)
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = safeUserMessage(for: error, context: .importData)
        }
    }

    private func importPreview(_ preview: CSVImportPreview) async {
        guard let fallbackAccountID,
              let fallbackExpenseCategoryID,
              let fallbackIncomeCategoryID else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let rows = preview.rows.map { row in
                ImportedTransaction(
                    id: row.id,
                    hasExternalID: row.hasExternalID,
                    legacyFingerprintCandidates: row.legacyFingerprintCandidates,
                    sourceLine: row.sourceLine,
                    kind: row.kind,
                    occurredAt: row.occurredAt,
                    originContext: row.originContext,
                    amount: row.amount,
                    destinationAmount: row.destinationAmount,
                    currencyCode: row.currencyCode ?? defaultCurrencyCode,
                    accountName: row.accountName,
                    destinationAccountName: row.destinationAccountName,
                    categoryName: row.categoryName,
                    payee: row.payee,
                    note: row.note
                )
            }
            let result = try await model.importTransactions(
                rows,
                fallbackAccountID: fallbackAccountID,
                fallbackExpenseCategoryID: fallbackExpenseCategoryID,
                fallbackIncomeCategoryID: fallbackIncomeCategoryID,
                accountMappings: accountMappings,
                expenseCategoryMappings: expenseCategoryMappings,
                incomeCategoryMappings: incomeCategoryMappings
            )
            message = String(
                format: AppLocalization.string("import.complete_format"),
                result.imported,
                result.duplicates,
                result.skipped + preview.issues.count
            )
            errorMessage = nil
            self.preview = nil
            inspection = nil
            sourceText = ""
        } catch {
            errorMessage = safeUserMessage(for: error, context: .importData)
        }
    }

    private func prepareReviewedMappings(for preview: CSVImportPreview?) {
        guard let preview else { return }
        accountMappings = CSVImportNameResolver.reviewedMappings(
            for: sourceAccountNames(in: preview)
        ) { name in
            exactAccount(named: name)?.id ?? fallbackAccountID
        }
        expenseCategoryMappings = CSVImportNameResolver.reviewedMappings(
            for: sourceCategoryNames(in: preview, kind: .expense)
        ) { name in
            exactCategory(named: name, kind: .expense)?.id
                ?? fallbackExpenseCategoryID
        }
        incomeCategoryMappings = CSVImportNameResolver.reviewedMappings(
            for: sourceCategoryNames(in: preview, kind: .income)
        ) { name in
            exactCategory(named: name, kind: .income)?.id
                ?? fallbackIncomeCategoryID
        }
    }

    private func sourceAccountNames(in preview: CSVImportPreview) -> [String] {
        CSVImportNameResolver.sourceNames(in: preview, domain: .account)
    }

    private func sourceCategoryNames(
        in preview: CSVImportPreview,
        kind: LedgerAccountKind
    ) -> [String] {
        CSVImportNameResolver.sourceNames(
            in: preview,
            domain: kind == .income ? .incomeCategory : .expenseCategory
        )
    }

    private func reviewedBinding(
        for name: String,
        in mappings: Binding<[String: UUID]>,
        fallback: UUID?
    ) -> Binding<UUID?> {
        let key = normalizedName(name)
        return Binding(
            get: { mappings.wrappedValue[key] ?? fallback },
            set: { value in
                if let value { mappings.wrappedValue[key] = value }
                else { mappings.wrappedValue.removeValue(forKey: key) }
            }
        )
    }

    private func exactAccount(named name: String) -> LedgerAccount? {
        let key = normalizedName(name)
        return eligibleAccounts.first { normalizedName($0.name) == key }
    }

    private func exactCategory(named name: String, kind: LedgerAccountKind) -> LedgerAccount? {
        let key = normalizedName(name)
        let choices = kind == .income ? model.incomeCategories : model.expenseCategories
        return choices.first { normalizedName($0.name) == key }
    }

    private func normalizedName(_ value: String) -> String {
        CSVImportNameResolver.normalizedKey(for: value)
    }

    private func localizedField(_ field: CSVImportMappedField) -> String {
        switch field {
        case .id: AppLocalization.string("import.field.id")
        case .date: AppLocalization.string("import.field.date")
        case .kind: AppLocalization.string("import.field.kind")
        case .amount: AppLocalization.string("import.field.amount")
        case .destinationAmount: AppLocalization.string("import.field.destinationAmount")
        case .currency: AppLocalization.string("import.field.currency")
        case .account: AppLocalization.string("import.field.account")
        case .destinationAccount: AppLocalization.string("import.field.destinationAccount")
        case .category: AppLocalization.string("import.field.category")
        case .payee: AppLocalization.string("import.field.payee")
        case .note: AppLocalization.string("import.field.note")
        case .outflow: AppLocalization.string("import.field.outflow")
        case .inflow: AppLocalization.string("import.field.inflow")
        }
    }

    private func localizedIssue(_ reason: String) -> String {
        switch reason {
        case "invalid_date": AppLocalization.string("import.issue.invalid_date")
        case "invalid_amount": AppLocalization.string("import.issue.invalid_amount")
        case "invalid_destination_amount":
            AppLocalization.string("import.issue.invalid_destination_amount")
        case "unsupported_type": AppLocalization.string("import.issue.unsupported_type")
        case "unsupported_adjustment": AppLocalization.string("import.issue.unsupported_adjustment")
        case "column_count_mismatch": AppLocalization.string("import.issue.column_count_mismatch")
        default: AppLocalization.string("import.issue.invalid_row")
        }
    }

    private func localizedKind(_ kind: ImportedTransactionKind) -> String {
        switch kind {
        case .expense: AppLocalization.string("transaction.expense")
        case .income: AppLocalization.string("transaction.income")
        case .transfer: AppLocalization.string("transaction.transfer")
        case .refund: AppLocalization.string("transaction.refund")
        }
    }
}

enum CSVImportViewError: LocalizedError {
    case unsupportedEncoding
    case requiresCSVExport
    case unsupportedDocument
    case documentTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: AppLocalization.string("import.error.encoding")
        case .requiresCSVExport: AppLocalization.string("import.error.requires_csv")
        case .unsupportedDocument: AppLocalization.string("import.error.document")
        case .documentTooLarge: AppLocalization.string("import.error.too_large")
        }
    }
}

extension TransactionCSVImportError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyFile: AppLocalization.string("import.error.empty")
        case .missingRequiredColumns: AppLocalization.string("import.error.columns")
        case .malformedCSV: AppLocalization.string("import.error.malformed")
        case .inputTooLarge: AppLocalization.string("import.error.too_large")
        case .tooManyRows: AppLocalization.string("import.error.too_many_rows")
        case .postingLevelExportRequiresArchive:
            AppLocalization.string("import.error.moneyup_export")
        }
    }
}
