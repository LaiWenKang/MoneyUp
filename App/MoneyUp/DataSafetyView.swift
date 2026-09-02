import MoneyUpPersistence
import SwiftUI
import UniformTypeIdentifiers

enum RestoreCompletionAccessibilityRoute: Equatable {
    case focusVisibleConfirmation
    case announceAfterRecoveryTransition

    init(initialState: AppModel.State) {
        self = initialState == .ready
            ? .focusVisibleConfirmation
            : .announceAfterRecoveryTransition
    }
}

enum RestoreOperationPresentation: Equatable {
    case success(String)
    case failure(String)
}

struct RestoreOperationPresentationState: Equatable {
    private(set) var pendingAfterSheetDismissal: RestoreOperationPresentation?
    private(set) var visibleSuccess: String?

    mutating func queue(_ presentation: RestoreOperationPresentation) {
        pendingAfterSheetDismissal = presentation
    }

    mutating func takeAfterSheetDismissal() -> RestoreOperationPresentation? {
        defer { pendingAfterSheetDismissal = nil }
        return pendingAfterSheetDismissal
    }

    mutating func presentVisibleSuccess(_ completion: String) {
        visibleSuccess = completion
    }

    mutating func clearVisibleSuccess() {
        visibleSuccess = nil
    }
}

struct DataSafetyView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PortableBackupReminder.storageKey)
    private var hasCreatedPortableBackup = false

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
    @State private var pendingRestoreTicket: RestorePreviewTicket?
    @State private var isConfirmingCaptureDiscard = false
    @State private var isConfirmingPendingCaptureDiscard = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var restorePresentation = RestoreOperationPresentationState()
    @AccessibilityFocusState private var successMessageIsFocused: Bool

    private var restoreDetailKey: LocalizedStringKey {
        model.startupFailureKind == .missingDeviceBoundKey
            ? "recovery.key_cliff.restore_detail"
            : "restore.detail"
    }

    var body: some View {
        Form {
            if model.startupFailureKind == .missingDeviceBoundKey {
                Section {
                    Label(
                        "recovery.key_cliff.detail",
                        systemImage: "key.slash.fill"
                    )
                    .foregroundStyle(.orange)
                    Text("recovery.key_cliff.steps")
                        .font(.callout)
                } header: {
                    Text("recovery.key_cliff.title")
                } footer: {
                    Text("recovery.key_cliff.archive_preserved")
                }
            } else if !hasCreatedPortableBackup {
                Section {
                    Label(
                        "backup.first_reminder",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }
            }

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
                    if model.startupFailureKind == .missingDeviceBoundKey {
                        Button(
                            "recovery.key_cliff.discard_pending",
                            role: .destructive
                        ) {
                            isConfirmingPendingCaptureDiscard = true
                        }
                        .disabled(isWorking)
                    }
                }
            }

            if model.recoveryIssueCount > 0 {
                Section {
                    Label(
                        String(
                            format: AppLocalization.string("recovery.quarantined_count"),
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

            if model.startupFailureKind != .missingDeviceBoundKey {
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
                            "inventory.loans",
                            value: "\(inventory.storedRecordCount(in: .loanPlans))"
                        )
                        LabeledContent(
                            "inventory.loan_activities",
                            value: "\(inventory.nestedActivityCounts.loanActivities)"
                        )
                        LabeledContent(
                            "inventory.allowances",
                            value: "\(inventory.storedRecordCount(in: .allowancePlans))"
                        )
                        LabeledContent(
                            "inventory.allowance_usages",
                            value: "\(inventory.nestedActivityCounts.allowanceUsages)"
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
                                ? AppLocalization.string("inventory.enabled")
                                : AppLocalization.string("inventory.disabled")
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
                            ? AppLocalization.string("inventory.generate")
                            : AppLocalization.string("inventory.refresh"),
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
                Text(restoreDetailKey)
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
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                }
                    .foregroundStyle(.green)
            }
            if let restoreSuccess = restorePresentation.visibleSuccess {
                Section {
                    Label(
                        restoreSuccess,
                        systemImage: "checkmark.circle.fill"
                    )
                    .accessibilityFocused($successMessageIsFocused)
                }
                .foregroundStyle(.green)
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
            } else {
                hasCreatedPortableBackup = true
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
        .sheet(
            item: $pendingRestoreTicket,
            onDismiss: presentRestoreResultAfterSheetDismissal
        ) { ticket in
            RestorePreviewConfirmationView(
                preview: ticket.preview,
                isWorking: isWorking,
                onCancel: discardPendingRestore,
                onConfirm: {
                    beginRestore(ticket)
                }
            )
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
        .confirmationDialog(
            "recovery.key_cliff.discard_pending_title",
            isPresented: $isConfirmingPendingCaptureDiscard,
            titleVisibility: .visible
        ) {
            Button(
                "recovery.key_cliff.discard_pending_confirm",
                role: .destructive
            ) {
                Task { await discardPendingKeyCliffCaptures() }
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("recovery.key_cliff.discard_pending_detail")
        }
        .onChange(of: model.logicalBookRevision) { _, _ in
            inventory = nil
            inventoryDocument = PrivacySafeDataInventoryDocument()
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
        .onDisappear {
            clearRestoreSuccessPresentation()
            importTask?.cancel()
            importTask = nil
            removeTemporaryFile(archiveTransfer?.fileURL)
            removeTemporaryFile(pendingRestoreURL)
            archiveTransfer = nil
            pendingRestoreURL = nil
            pendingRestoreTicket = nil
            restorePassword = ""
        }
    }
}

extension DataSafetyView {
    private func createBackup() async {
        guard backupPassword == backupConfirmation else { return }
        clearRestoreSuccessPresentation()
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
            message = AppLocalization.string("backup.ready")
        } catch {
            removeTemporaryFile(createdArchiveURL)
            errorMessage = safeUserMessage(for: error, context: .exportData)
        }
    }

    private func refreshInventory() async {
        clearRestoreSuccessPresentation()
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
            message = AppLocalization.string("inventory.ready")
        } catch {
            errorMessage = safeUserMessage(for: error, context: .exportData)
        }
    }

    private func beginRestore(_ ticket: RestorePreviewTicket) {
        guard !isWorking else { return }
        isWorking = true
        importTask = Task { await restoreBackup(ticket) }
    }

    private func restoreBackup(_ ticket: RestorePreviewTicket) async {
        let accessibilityRoute = RestoreCompletionAccessibilityRoute(
            initialState: model.state
        )
        errorMessage = nil
        message = nil
        clearRestoreSuccessPresentation()
        let completion = AppLocalization.string("restore.complete")
        if accessibilityRoute == .announceAfterRecoveryTransition {
            // Queue before the model publishes `.ready`; MainTabView can then
            // consume on either appearance ordering without losing the event.
            model.queueRestoreCompletionForReadyHierarchy(completion)
        }
        defer {
            isWorking = false
            removeTemporaryFile(pendingRestoreURL)
            self.pendingRestoreURL = nil
            pendingRestoreTicket = nil
            restorePassword = ""
        }
        do {
            try await model.restoreEncryptedBackup(
                ticket,
                password: restorePassword
            )
            hasCreatedPortableBackup = true
            if accessibilityRoute == .focusVisibleConfirmation {
                restorePresentation.queue(.success(completion))
            }
        } catch {
            if accessibilityRoute == .announceAfterRecoveryTransition {
                model.clearRestoreCompletionForReadyHierarchy()
            }
            restorePresentation.queue(
                .failure(safeUserMessage(for: error, context: .restoreData))
            )
        }
    }

    private func presentRestoreResultAfterSheetDismissal() {
        guard let presentation = restorePresentation
            .takeAfterSheetDismissal() else {
            discardPendingRestore()
            return
        }
        switch presentation {
        case let .success(completion):
            restorePresentation.presentVisibleSuccess(completion)
            Task { @MainActor in
                await Task.yield()
                guard restorePresentation.visibleSuccess == completion else {
                    return
                }
                successMessageIsFocused = true
            }
        case let .failure(failure):
            errorMessage = failure
        }
    }

    private func stageRestoreArchive(from sourceURL: URL) async {
        clearRestoreSuccessPresentation()
        isWorking = true
        errorMessage = nil
        message = nil
        let importedURL = model.restoreStagedArchiveURL
        removeTemporaryFile(importedURL)
        defer {
            isWorking = false
        }
        let copyTask = Task.detached(priority: .userInitiated) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }
            let values = try sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true else {
                throw PortableArchiveError.invalidArchive
            }
            if let fileSize = values.fileSize,
               !PortableArchive.isWithinArchiveByteLimit(fileSize) {
                throw PortableArchiveError.archiveTooLarge
            }
            let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? sourceHandle.close() }
            let byteCount = try BoundedFileReader.copy(
                from: sourceHandle,
                to: importedURL,
                maximumByteCount: PortableArchive.maximumArchiveByteCount
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: importedURL.path
            )
            return byteCount
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
            let password = restorePassword
            let ticket = try await model.prepareEncryptedRestorePreview(
                from: importedURL,
                password: password
            )
            try Task.checkCancellation()
            removeTemporaryFile(pendingRestoreURL)
            pendingRestoreURL = importedURL
            pendingRestoreTicket = ticket
        } catch is CancellationError {
            removeTemporaryFile(importedURL)
        } catch {
            removeTemporaryFile(importedURL)
            errorMessage = safeUserMessage(for: error, context: .restoreData)
        }
    }

    private func discardPendingRestore() {
        guard !isWorking else { return }
        removeTemporaryFile(pendingRestoreURL)
        pendingRestoreURL = nil
        pendingRestoreTicket = nil
        restorePassword = ""
    }

    private func removeTemporaryFile(_ url: URL?) {
        guard let url,
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func discardUnavailableCaptures() async {
        clearRestoreSuccessPresentation()
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do {
            try await model.discardUnavailableLockedCaptures()
            message = AppLocalization.string("capture.unavailable.discarded")
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func discardPendingKeyCliffCaptures() async {
        clearRestoreSuccessPresentation()
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do {
            try await model.discardPendingLockedCapturesForKeyCliffRecovery()
            message = AppLocalization.string(
                "recovery.key_cliff.pending_discarded"
            )
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func clearRestoreSuccessPresentation() {
        restorePresentation.clearVisibleSuccess()
        successMessageIsFocused = false
    }
}
