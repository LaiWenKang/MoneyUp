import MoneyUpCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportTransactionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isChoosingFile = false
    @State private var preview: CSVImportPreview?
    @State private var fileName = ""
    @State private var fallbackAccountID: UUID?
    @State private var fallbackExpenseCategoryID: UUID?
    @State private var fallbackIncomeCategoryID: UUID?
    @State private var isImporting = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Button {
                    isChoosingFile = true
                } label: {
                    Label("import.choose_csv", systemImage: "tablecells.badge.ellipsis")
                }
                if !fileName.isEmpty {
                    LabeledContent("import.file", value: fileName)
                }
            } header: {
                Text("import.qianji_and_csv")
            } footer: {
                Text("import.local_only_detail")
            }

            if let preview {
                Section {
                    LabeledContent("import.ready", value: "\(preview.rows.count)")
                    LabeledContent("import.needs_review", value: "\(preview.issues.count)")
                    if !preview.issues.isEmpty {
                        DisclosureGroup("import.review_issues") {
                            ForEach(preview.issues.prefix(20)) { issue in
                                Text("\(String(localized: "import.line")) \(issue.line): \(localizedIssue(issue.reason))")
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
                    Picker("settings.default_account", selection: $fallbackAccountID) {
                        ForEach(model.userAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
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
                                "\(row.currencyCode ?? model.profile?.baseCurrency.value ?? "") \(NSDecimalNumber(decimal: row.amount).stringValue)"
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
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("import.title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selectDefaults() }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileResult(result)
        }
    }

    private func selectDefaults() {
        fallbackAccountID = model.profile?.preferredAccountID
            .flatMap { preferred in
                model.userAccounts.contains(where: { $0.id == preferred }) ? preferred : nil
            } ?? model.userAccounts.first?.id
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
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 10_000_000 else { throw AppModelError.importTooLarge }
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
            guard let text else { throw CSVImportViewError.unsupportedEncoding }
            preview = try TransactionCSVImporter.parse(text)
            fileName = url.lastPathComponent
            message = nil
            errorMessage = nil
        } catch {
            preview = nil
            fileName = ""
            errorMessage = error.localizedDescription
        }
    }

    private func importPreview(_ preview: CSVImportPreview) async {
        guard let fallbackAccountID,
              let fallbackExpenseCategoryID,
              let fallbackIncomeCategoryID else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await model.importTransactions(
                preview.rows,
                fallbackAccountID: fallbackAccountID,
                fallbackExpenseCategoryID: fallbackExpenseCategoryID,
                fallbackIncomeCategoryID: fallbackIncomeCategoryID
            )
            message = String(
                format: String(localized: "import.complete_format"),
                result.imported,
                result.duplicates,
                result.skipped + preview.issues.count
            )
            errorMessage = nil
            self.preview = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func localizedIssue(_ reason: String) -> String {
        switch reason {
        case "invalid_date": String(localized: "import.issue.invalid_date")
        case "invalid_amount": String(localized: "import.issue.invalid_amount")
        case "unsupported_type": String(localized: "import.issue.unsupported_type")
        default: String(localized: "import.issue.invalid_row")
        }
    }

    private func localizedKind(_ kind: ImportedTransactionKind) -> String {
        switch kind {
        case .expense: String(localized: "transaction.expense")
        case .income: String(localized: "transaction.income")
        case .transfer: String(localized: "transaction.transfer")
        case .refund: String(localized: "transaction.refund")
        }
    }
}

private enum CSVImportViewError: LocalizedError {
    case unsupportedEncoding

    var errorDescription: String? {
        String(localized: "import.error.encoding")
    }
}

extension TransactionCSVImportError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyFile: String(localized: "import.error.empty")
        case .missingRequiredColumns: String(localized: "import.error.columns")
        case .malformedCSV: String(localized: "import.error.malformed")
        case .postingLevelExportRequiresArchive:
            String(localized: "import.error.moneyup_export")
        }
    }
}
