import SwiftUI
import UIKit

struct CloudBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: CloudBackupController
    let onDownload: @MainActor (URL, String) async -> Void
    @State private var signIn = CloudBackupSignIn()
    @State private var label = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var savedPassword = false
    @State private var restorePassword = ""
    @State private var backupToDelete: CloudBackupManifest?
    @State private var confirmingDisconnect = false

    var body: some View {
        Form {
            if controller.configuration.isInternalBeta {
                Section {
                    Label("cloud.beta.detail", systemImage: "info.circle")
                        .font(.callout)
                }
            }
            Section {
                Text("cloud.detail")
                Label(LocalizedStringKey(controller.phase.rawValue), systemImage: "icloud")
                if let detail = controller.failureDetail { Text(detail).foregroundStyle(.secondary) }
                if !controller.accountLabel.isEmpty {
                    LabeledContent("cloud.account_label", value: controller.accountLabel)
                }
                if let last = controller.lastSuccessfulBackup {
                    LabeledContent("cloud.last_backup", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if !controller.isConnected || controller.phase == .reconnect {
                Section {
                    TextField("cloud.account_label_optional", text: $label)
                        .textInputAutocapitalization(.sentences)
                    Button("cloud.connect") {
                        Task { await controller.connectAccount(using: signIn, label: label) }
                    }
                    .disabled(controller.isWorking)
                } footer: { Text("cloud.apple_sign_in_detail") }
            }
            if controller.isConnected {
                backupSettings
                restoreSection
                Section {
                    Button("cloud.disconnect", role: .destructive) { confirmingDisconnect = true }
                }
            }
            if controller.isWorking { Section { ProgressView("action.working") } }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("cloud.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { signIn.cancel(); dismiss() } } }
        .background(CloudBackupWindowAnchor { signIn.anchor = $0 }.frame(width: 0, height: 0))
        .moneyUpOperationErrorAlert(message: $controller.errorMessage)
        .task { await controller.loadStatus() }
        .confirmationDialog("cloud.disconnect_title", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("cloud.disconnect", role: .destructive) { Task { await controller.disconnect() } }
            Button("action.cancel", role: .cancel) {}
        } message: { Text("cloud.disconnect_detail") }
        .confirmationDialog("cloud.delete_title", isPresented: Binding(
            get: { backupToDelete != nil }, set: { if !$0 { backupToDelete = nil } }), titleVisibility: .visible) {
            if let backup = backupToDelete {
                Button("cloud.delete", role: .destructive) {
                    backupToDelete = nil
                    Task { await controller.delete(backup) }
                }
            }
            Button("action.cancel", role: .cancel) { backupToDelete = nil }
        } message: { Text("cloud.delete_detail") }
        .onDisappear {
            if controller.phase == .downloading { controller.cancelTransfers() }
            password = ""
            confirmation = ""
            restorePassword = ""
        }
    }

    private var backupSettings: some View {
        Section {
            if controller.automaticEnabled {
                Label("cloud.automatic_on", systemImage: "checkmark.shield")
                Button("cloud.back_up_now") { Task { await controller.backUpNow(model: model) } }
                    .disabled(controller.isWorking || model.state != .ready)
                Button("cloud.pause") { Task { await controller.pauseAutomatic() } }
            } else if model.state == .ready {
                SecureField("cloud.recovery_password", text: $password).textContentType(.newPassword)
                SecureField("backup.password_confirm", text: $confirmation).textContentType(.newPassword)
                Toggle("cloud.saved_password", isOn: $savedPassword)
                Button("cloud.enable") {
                    Task {
                        await controller.enableBackup(model: model, password: password,
                            confirmation: confirmation, savedRecoveryPassword: savedPassword)
                        if controller.automaticEnabled { password = ""; confirmation = ""; savedPassword = false }
                    }
                }
                .disabled(controller.isWorking || !savedPassword || password.count < 10 || password != confirmation)
            }
        } header: { Text("cloud.automatic_title") }
        footer: { Text("cloud.recovery_password_detail") }
    }

    private var restoreSection: some View {
        Section {
            Button("cloud.load_backups") { Task { await controller.listBackups() } }
                .disabled(controller.isWorking)
            if !controller.backups.isEmpty {
                SecureField("cloud.recovery_password", text: $restorePassword).textContentType(.password)
                ForEach(controller.backups) { backup in
                    Button {
                        Task {
                            let password = restorePassword
                            await controller.download(backup) { url in await onDownload(url, password) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("cloud.restore_hint")
                    .disabled(controller.isWorking || restorePassword.isEmpty)
                    .swipeActions { Button("cloud.delete", role: .destructive) { backupToDelete = backup } }
                }
                if controller.continuation != nil {
                    Button("cloud.load_more") { Task { await controller.listBackups(loadMore: true) } }
                        .disabled(controller.isWorking)
                }
            }
        } header: { Text("cloud.history") }
        footer: { Text("cloud.history_detail") }
    }
}

private struct CloudBackupWindowAnchor: UIViewRepresentable {
    let onWindow: @MainActor (UIWindow?) -> Void
    func makeUIView(context: Context) -> CloudBackupAnchorView { CloudBackupAnchorView(onWindow: onWindow) }
    func updateUIView(_ uiView: CloudBackupAnchorView, context: Context) { onWindow(uiView.window) }
}

private final class CloudBackupAnchorView: UIView {
    let onWindow: @MainActor (UIWindow?) -> Void
    init(onWindow: @escaping @MainActor (UIWindow?) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func didMoveToWindow() { super.didMoveToWindow(); onWindow(window) }
}
