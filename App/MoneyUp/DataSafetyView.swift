import MoneyUpPersistence
import SwiftUI
import UniformTypeIdentifiers

struct DataSafetyView: View {
    @Environment(AppModel.self) private var model

    @State private var backupPassword = ""
    @State private var backupConfirmation = ""
    @State private var restorePassword = ""
    @State private var archiveTransfer: MoneyUpArchiveTransfer?
    @State private var inventory: PrivacySafeDataInventory?
    @State private var inventoryDocument = PrivacySafeDataInventoryDocument()
    @State private var isExporting = false
    @State private var isExportingInventory = false
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var pendingRestoreURL: URL?
    @State private var isConfirmingRestore = false
    @State private var isConfirmingCaptureDiscard = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if model.lockedCaptureInboxIsUnrecoverable {
                Section {
                    Label(
                        "capture.unavailable.detail",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Button("capture.unavailable.discard", role: .destructive) {
                        isConfirmingCaptureDiscard = true
                    }
                    .disabled(isWorking)
                } header: {
                    Text("capture.unavailable.title")
                }
            }

            if model.pendingLockedCaptureCount > 0 {
                Section {
                    Label(
                        "backup.pending_captures_blocked",
                        systemImage: "tray.full.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

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
                        || model.pendingLockedCaptureCount > 0
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
                .disabled(
                    isWorking
                        || model.pendingLockedCaptureCount > 0
                        || restorePassword.isEmpty
                )
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
            item: archiveTransfer,
            contentTypes: [.moneyUpArchive],
            defaultFilename: "MoneyUp-Backup.moneyup"
        ) { result in
            removeTemporaryFile(archiveTransfer?.fileURL)
            archiveTransfer = nil
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
                importTask?.cancel()
                importTask = Task { await stageRestoreArchive(from: url) }
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
                removeTemporaryFile(pendingRestoreURL)
                pendingRestoreURL = nil
            }
        } message: {
            Text("restore.confirm_detail")
        }
        .confirmationDialog(
            "capture.unavailable.confirm_title",
            isPresented: $isConfirmingCaptureDiscard,
            titleVisibility: .visible
        ) {
            Button("capture.unavailable.discard", role: .destructive) {
                Task { await discardUnavailableCaptures() }
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("capture.unavailable.confirm_detail")
        }
        .onDisappear {
            importTask?.cancel()
            importTask = nil
            removeTemporaryFile(archiveTransfer?.fileURL)
            removeTemporaryFile(pendingRestoreURL)
            archiveTransfer = nil
            pendingRestoreURL = nil
        }
    }

    private func createBackup() async {
        guard backupPassword == backupConfirmation else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        var createdArchiveURL: URL?
        defer { isWorking = false }
        do {
            let password = backupPassword
            let archiveURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "MoneyUp-Backup-\(UUID().uuidString).moneyup",
                    isDirectory: false
                )
            createdArchiveURL = archiveURL
            removeTemporaryFile(archiveTransfer?.fileURL)
            try await model.encryptedBackup(
                to: archiveURL,
                password: password
            )
            archiveTransfer = MoneyUpArchiveTransfer(fileURL: archiveURL)
            backupPassword = ""
            backupConfirmation = ""
            isExporting = true
            message = String(localized: "backup.ready")
        } catch {
            removeTemporaryFile(createdArchiveURL)
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
        guard let pendingRestoreURL else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer {
            isWorking = false
            removeTemporaryFile(pendingRestoreURL)
            self.pendingRestoreURL = nil
            restorePassword = ""
        }
        do {
            try await model.restoreEncryptedBackup(
                from: pendingRestoreURL,
                password: restorePassword
            )
            message = String(localized: "restore.complete")
        } catch {
            errorMessage = safeUserMessage(for: error, context: .restoreData)
        }
    }

    private func stageRestoreArchive(from sourceURL: URL) async {
        isWorking = true
        errorMessage = nil
        message = nil
        let importedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Imported-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        defer {
            isWorking = false
        }
        let copyTask = Task.detached(priority: .userInitiated) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }
            let fileSize = try sourceURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
            if let fileSize,
               !PortableArchive.isWithinArchiveByteLimit(fileSize) {
                throw PortableArchiveError.archiveTooLarge
            }
            let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? sourceHandle.close() }
            return try BoundedFileReader.copy(
                from: sourceHandle,
                to: importedURL,
                maximumByteCount: PortableArchive.maximumArchiveByteCount
            )
        }
        do {
            let copiedByteCount = try await withTaskCancellationHandler {
                try await copyTask.value
            } onCancel: {
                copyTask.cancel()
            }
            try Task.checkCancellation()
            guard PortableArchive.isWithinArchiveByteLimit(
                copiedByteCount
            ) else {
                throw PortableArchiveError.archiveTooLarge
            }
            removeTemporaryFile(pendingRestoreURL)
            pendingRestoreURL = importedURL
            isConfirmingRestore = true
        } catch is CancellationError {
            removeTemporaryFile(importedURL)
        } catch {
            removeTemporaryFile(importedURL)
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }

    private func removeTemporaryFile(_ url: URL?) {
        guard let url,
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func discardUnavailableCaptures() async {
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do {
            try await model.discardUnavailableLockedCaptures()
            message = String(localized: "capture.unavailable.discarded")
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
