import SwiftUI
import UniformTypeIdentifiers

struct DataSafetyView: View {
    @EnvironmentObject private var model: AppModel

    @State private var backupPassword = ""
    @State private var backupConfirmation = ""
    @State private var restorePassword = ""
    @State private var archiveDocument = MoneyUpArchiveDocument()
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var pendingRestoreData: Data?
    @State private var isConfirmingRestore = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if !model.recoveryIssues.isEmpty {
                Section {
                    Label(
                        String(
                            format: String(localized: "recovery.quarantined_count"),
                            model.recoveryIssues.count
                        ),
                        systemImage: "exclamationmark.shield"
                    )
                    DisclosureGroup("recovery.details") {
                        ForEach(model.recoveryIssues, id: \.self) { issue in
                            Text(issue)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("recovery.integrity")
                } footer: {
                    Text("recovery.quarantined_detail")
                }
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
                errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }
}
