import MoneyUpPersistence
import SwiftUI
import UniformTypeIdentifiers

struct DataSafetyView: View {
    @EnvironmentObject private var model: AppModel

    @State private var backupPassword = ""
    @State private var backupConfirmation = ""
    @State private var restorePassword = ""
    @State private var archiveDocument = MoneyUpArchiveDocument()
    @State private var inventory: PrivacySafeDataInventory?
    @State private var inventoryDocument = PrivacySafeDataInventoryDocument()
    @State private var isExporting = false
    @State private var isExportingInventory = false
    @State private var isImporting = false
    @State private var pendingRestoreData: Data?
    @State private var isConfirmingRestore = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if model.recoveryIssueCount > 0 {
                Section {
                    Label(
                        String(
                            format: String(localized: "recovery.quarantined_count"),
                            model.recoveryIssueCount
                        ),
                        systemImage: "exclamationmark.shield"
                    )
                    DisclosureGroup("recovery.details") {
                        ForEach(model.recoveryIssueSummaries, id: \.self) { summary in
                            Text(summary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("recovery.integrity")
                } footer: {
                    Text("recovery.quarantined_detail")
                }
            }

            Section {
                if let inventory {
                    LabeledContent(
                        "inventory.version_build",
                        value: "\(inventory.appVersion) (\(inventory.buildNumber))"
                    )
                    LabeledContent(
                        "inventory.schema",
                        value: "\(inventory.databaseSchemaVersion)"
                    )
                    LabeledContent(
                        "inventory.transactions",
                        value: "\(inventory.storedRecordCount(in: .journalEntries))"
                    )
                    LabeledContent(
                        "inventory.accounts",
                        value: "\(inventory.storedRecordCount(in: .accounts))"
                    )

                    DisclosureGroup("inventory.more_counts") {
                        LabeledContent(
                            "inventory.budgets",
                            value: "\(inventory.storedRecordCount(in: .budgetNodes))"
                        )
                        LabeledContent(
                            "inventory.schedules",
                            value: "\(inventory.storedRecordCount(in: .scheduledTransactions))"
                        )
                        LabeledContent(
                            "inventory.holdings",
                            value: "\(inventory.storedRecordCount(in: .investmentHoldings))"
                        )
                        LabeledContent(
                            "inventory.lots",
                            value: "\(inventory.nestedActivityCounts.investmentLots)"
                        )
                        LabeledContent(
                            "inventory.goals",
                            value: "\(inventory.storedRecordCount(in: .savingsGoals))"
                        )
                        LabeledContent(
                            "inventory.goal_movements",
                            value: "\(inventory.nestedActivityCounts.savingsGoalMovements)"
                        )
                        LabeledContent(
                            "inventory.receipts",
                            value: "\(inventory.storedRecordCount(in: .receiptAttachments))"
                        )
                        LabeledContent(
                            "inventory.rates",
                            value: "\(inventory.storedRecordCount(in: .exchangeRates))"
                        )
                        LabeledContent(
                            "inventory.snapshots",
                            value: "\(inventory.storedRecordCount(in: .netWorthSnapshots))"
                        )
                        LabeledContent(
                            "inventory.pending_captures",
                            value: "\(inventory.pendingLockedCaptureCount)"
                        )
                        LabeledContent(
                            "inventory.widget_budget_status",
                            value: inventory.budgetStatusWidgetEnabled
                                ? String(localized: "inventory.enabled")
                                : String(localized: "inventory.disabled")
                        )
                        LabeledContent(
                            "inventory.quarantined",
                            value: "\(inventory.quarantinedRecordCount)"
                        )
                    }

                    if !inventory.nestedActivityCountsComplete {
                        Label("inventory.partial", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button {
                        inventoryDocument = PrivacySafeDataInventoryDocument(
                            inventory: inventory
                        )
                        isExportingInventory = true
                    } label: {
                        Label("inventory.export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isWorking)
                }

                Button {
                    Task { await refreshInventory() }
                } label: {
                    Label(
                        inventory == nil
                            ? String(localized: "inventory.generate")
                            : String(localized: "inventory.refresh"),
                        systemImage: "list.number"
                    )
                }
                .disabled(isWorking)
            } header: {
                Text("inventory.title")
            } footer: {
                Text("inventory.detail")
            }

            Section {
                SecureField("backup.password", text: $backupPassword)
                    .textContentType(.newPassword)
                SecureField("backup.password_confirm", text: $backupConfirmation)
                    .textContentType(.newPassword)

                Button {
                    Task { await createBackup() }
                } label: {
                    Label("backup.create", systemImage: "lock.doc")
                }
                .disabled(
                    isWorking
                        || backupPassword.count < 10
                        || backupPassword != backupConfirmation
                )
            } header: {
                Text("backup.title")
            } footer: {
                Text("backup.detail")
            }

            Section {
                SecureField("backup.password", text: $restorePassword)
                    .textContentType(.password)

                Button {
                    isImporting = true
                } label: {
                    Label("restore.choose", systemImage: "externaldrive.badge.plus")
                }
                .disabled(isWorking || restorePassword.isEmpty)
            } header: {
                Text("restore.title")
            } footer: {
                Text("restore.detail")
            }

            if isWorking {
                Section {
                    HStack {
                        ProgressView()
                        Text("action.working")
                    }
                }
            }
            if let message {
                Section { Label(message, systemImage: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Section { Text(errorMessage) }
                    .foregroundStyle(.red)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("backup.data_safety")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: archiveDocument,
            contentType: .moneyUpArchive,
            defaultFilename: "MoneyUp-Backup.moneyup"
        ) { result in
            if case let .failure(error) = result {
                errorMessage = safeUserMessage(for: error, context: .write)
            }
        }
        .fileExporter(
            isPresented: $isExportingInventory,
            document: inventoryDocument,
            contentType: .json,
            defaultFilename: inventory?.defaultFilename ?? "MoneyUp-Inventory.json"
        ) { result in
            if case let .failure(error) = result {
                errorMessage = safeUserMessage(for: error, context: .write)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.moneyUpArchive],
            allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= 250_000_000 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                pendingRestoreData = try Data(contentsOf: url, options: [.mappedIfSafe])
                isConfirmingRestore = true
            } catch {
                errorMessage = safeUserMessage(for: error, context: .read)
            }
        }
        .confirmationDialog(
            "restore.confirm_title",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("restore.confirm", role: .destructive) {
                Task { await restoreBackup() }
            }
            Button("action.cancel", role: .cancel) {
                pendingRestoreData = nil
            }
        } message: {
            Text("restore.confirm_detail")
        }
    }

    private func createBackup() async {
        guard backupPassword == backupConfirmation else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do {
            archiveDocument = MoneyUpArchiveDocument(
                data: try await model.encryptedBackup(password: backupPassword)
            )
            isExporting = true
            message = String(localized: "backup.ready")
        } catch {
            errorMessage = safeUserMessage(for: error, context: .exportData)
        }
    }

    private func refreshInventory() async {
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do {
            let refreshed = try await model.privacySafeDataInventory()
            inventory = refreshed
            inventoryDocument = PrivacySafeDataInventoryDocument(
                inventory: refreshed
            )
            message = String(localized: "inventory.ready")
        } catch {
            errorMessage = safeUserMessage(for: error, context: .exportData)
        }
    }

    private func restoreBackup() async {
        guard let pendingRestoreData else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer {
            isWorking = false
            self.pendingRestoreData = nil
        }
        do {
            try await model.restoreEncryptedBackup(
                pendingRestoreData,
                password: restorePassword
            )
            message = String(localized: "restore.complete")
        } catch {
            errorMessage = safeUserMessage(for: error, context: .restoreData)
        }
    }
}
