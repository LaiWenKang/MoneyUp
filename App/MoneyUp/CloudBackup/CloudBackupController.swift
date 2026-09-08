import Foundation
import MoneyUpPersistence
import Observation

@MainActor
@Observable
final class CloudBackupController {
    enum Phase: String {
        case disconnected = "cloud.status.disconnected", connected = "cloud.status.connected"
        case signingIn = "cloud.status.signing_in", uploading = "cloud.status.uploading"
        case downloading = "cloud.status.downloading", paused = "cloud.status.paused"
        case reconnect = "cloud.status.reconnect", waiting = "cloud.status.waiting"
        case backedUp = "cloud.status.backed_up"
    }
    let configuration: CloudBackupConfiguration
    private let vault: any CloudBackupVault
    private let transport: any CloudBackupHTTPTransporting
    private let outboxRoot: URL
    private var work: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var requiresBackupConsent = false
    private var lastRevision: (generation: Int, revision: Int64)?
    private var nextAutomaticAttempt: Date = .distantPast
    private var lastAutomaticObservation: Date?
    private(set) var isWorking = false
    private(set) var isConnected = false
    private(set) var automaticEnabled = false
    private(set) var accountLabel = ""
    private(set) var lastSuccessfulBackup: Date?
    private(set) var phase: Phase = .disconnected
    private(set) var failureDetail: String?
    private(set) var backups: [CloudBackupManifest] = []
    private(set) var continuation: String?
    var errorMessage: String?

    init(configuration: CloudBackupConfiguration, vault: any CloudBackupVault,
        transport: any CloudBackupHTTPTransporting, outboxRoot: URL) {
        self.configuration = configuration
        self.vault = vault
        self.transport = transport
        self.outboxRoot = outboxRoot
    }

    static func configured() -> CloudBackupController? {
        guard let configuration = CloudBackupConfiguration.bundled(),
              let root = try? CloudBackupOutbox.rootURL() else { return nil }
        return CloudBackupController(configuration: configuration,
            vault: CloudBackupKeychainVault(configurationID: configuration.identity),
            transport: CloudBackupHTTPTransport(), outboxRoot: root)
    }

    func loadStatus() async {
        do { publish(try await vault.load()) }
        catch { failureDetail = safeUserMessage(for: error) }
    }

    func connectAccount(using signIn: any CloudBackupAuthenticating, label: String) async {
        await perform(phase: .signingIn) { [self] in
            let old = try await vault.load()
            try await vault.pauseAutomatic()
            automaticEnabled = false
            let initial = CloudKitWebClient(configuration: configuration, transport: transport)
            let url = try await initial.signInURL()
            let token = try await signIn.authenticate(at: url, configuration: configuration)
            let client = CloudKitWebClient(configuration: configuration, transport: transport, webToken: token)
            var account = try await client.verifiedAccount()
            try Task.checkCancellation()
            account.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            // Reconnection to the same verified account retains its recovery
            // password. Connecting another account never carries that consent.
            if old?.userRecordName == account.userRecordName, old?.configurationID == account.configurationID {
                account.bookID = old?.bookID
                account.recoveryPassword = old?.recoveryPassword
                account.recoveryContextID = old?.recoveryContextID
                account.lastSuccessfulBackup = old?.lastSuccessfulBackup
                if account.label.isEmpty { account.label = old?.label ?? "" }
            }
            try await vault.save(account)
            publish(account)
            requiresBackupConsent = true
            lastRevision = nil
            backups = []
            continuation = nil
            phase = .connected
        }
    }

    func enableBackup(model: AppModel, password: String, confirmation: String,
        savedRecoveryPassword: Bool) async {
        var enabled = false
        await perform(phase: .connected) { [self] in
            let logicalRevision = model.logicalBookRevision
            guard savedRecoveryPassword, password.count >= 10,
                  password.utf8.count <= PortableArchive.maximumPasswordByteCount,
                  password == confirmation else { throw CloudBackupError.recoveryPasswordRequired }
            var account = try await requireAccount()
            _ = try await client(for: account).verifiedAccount()
            try Task.checkCancellation()
            guard let bookID = try await model.cloudBackupBookID(createIfMissing: true) else {
                throw CloudBackupError.localStorage
            }
            // Token rotation may have happened while verifying the account.
            account = try await requireAccount()
            try Task.checkCancellation()
            guard model.logicalBookRevision == logicalRevision, !model.isBookReplacementInProgress else {
                throw CloudBackupError.accountChanged
            }
            if account.bookID != bookID || account.recoveryPassword != password || account.recoveryContextID == nil {
                account.recoveryContextID = UUID()
            }
            guard let context = account.recoveryContextID else { throw CloudBackupError.localStorage }
            account = try await vault.enableBackup(connectionID: account.connectionID,
                consentRevision: account.consentRevision, bookID: bookID, password: password, recoveryContextID: context)
            requiresBackupConsent = false
            lastRevision = nil
            nextAutomaticAttempt = .distantPast
            publish(account)
            enabled = true
        }
        if enabled && automaticEnabled { await backUpNow(model: model) }
    }

    func backUpNow(model: AppModel, automatic: Bool = false) async {
        await perform(phase: .uploading, reportError: !automatic) { [self] in
            let account = try await requireAccount()
            guard !requiresBackupConsent, account.automaticEnabled,
                  let bookID = account.bookID, let password = account.recoveryPassword,
                  let recoveryContextID = account.recoveryContextID,
                  model.state == .ready, try await model.cloudBackupBookID() == bookID else {
                throw CloudBackupError.recoveryPasswordRequired
            }
            let logicalRevision = model.logicalBookRevision
            let generation = model.storeGeneration
            let outbox = try CloudBackupOutbox(root: outboxRoot, configurationID: configuration.identity,
                userRecordName: account.userRecordName, bookID: bookID, recoveryContextID: recoveryContextID)
            try await outbox.prepareDirectory()
            let archiveURL = await outbox.archiveURL
            let manifest: CloudBackupManifest
            var snapshotRevision: Int64?
            if let pending = try await outbox.pending(bookID: bookID) { manifest = pending }
            else {
                snapshotRevision = try await model.encryptedBackup(to: archiveURL, password: password)
                manifest = try await outbox.stage(bookID: bookID)
            }
            try Task.checkCancellation()
            guard model.logicalBookRevision == logicalRevision, model.state == .ready else { throw AppModelError.locked }
            try await client(for: account).upload(manifest, archiveURL: archiveURL)
            try Task.checkCancellation()
            guard model.logicalBookRevision == logicalRevision else { throw CloudBackupError.accountChanged }
            let latest = try await vault.recordSuccess(manifest.createdAt, connectionID: account.connectionID,
                bookID: bookID, recoveryContextID: recoveryContextID)
            publish(latest)
            if let snapshotRevision { lastRevision = (generation, snapshotRevision) }
            nextAutomaticAttempt = Date().addingTimeInterval(300)
            phase = automaticEnabled ? .backedUp : .paused
            try? await outbox.complete(manifest)
        }
    }

    func listBackups(loadMore: Bool = false) async {
        await perform(phase: .connected) { [self] in
            let account = try await requireAccount()
            let page = try await client(for: account).listBackups(continuation: loadMore ? continuation : nil)
            let existing = loadMore ? backups : []
            let ids = Set(existing.map(\.id))
            backups = existing + page.backups.filter { !ids.contains($0.id) }
            continuation = page.continuation
        }
    }

    func download(_ backup: CloudBackupManifest,
        completion: @escaping @MainActor (URL) async throws -> Void) async {
        await perform(phase: .downloading) { [self] in
            let account = try await requireAccount()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoneyUp-Cloud-\(UUID().uuidString).moneyup")
            defer { try? FileManager.default.removeItem(at: url) }
            try await client(for: account).download(backup, to: url)
            try Task.checkCancellation()
            try await completion(url)
            phase = .connected
        }
    }

    func delete(_ backup: CloudBackupManifest) async {
        await perform(phase: .connected) { [self] in
            let account = try await requireAccount()
            try await client(for: account).delete(backup)
            backups.removeAll { $0.id == backup.id }
        }
    }

    func pauseForBookReplacement() {
        requiresBackupConsent = true
        automaticEnabled = false
        lastRevision = nil
        cancelTransfers()
        phase = .paused
        Task { [vault] in try? await vault.pauseAutomatic() }
    }

    func pauseAutomatic() async {
        requiresBackupConsent = true
        automaticEnabled = false
        cancelTransfers()
        await work?.value
        do { try await vault.pauseAutomatic(); phase = .paused }
        catch { errorMessage = safeUserMessage(for: error) }
    }

    func cancelTransfers() {
        if phase != .signingIn { work?.cancel() }
    }

    func disconnect() async {
        requiresBackupConsent = true
        automaticEnabled = false
        epoch &+= 1
        let pending = work
        pending?.cancel()
        await pending?.value
        do {
            try await vault.clear()
            publish(nil)
            backups = []
            continuation = nil
            phase = .disconnected
            failureDetail = nil
        } catch { errorMessage = safeUserMessage(for: error) }
    }

    func runAutomaticBackups(model: AppModel) async {
        await loadStatus()
        while !Task.isCancelled {
            await automaticTick(model: model, now: Date())
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
        }
    }

    func automaticTick(model: AppModel, now: Date) async {
        if let lastAutomaticObservation, now < lastAutomaticObservation { nextAutomaticAttempt = .distantPast }
        lastAutomaticObservation = now
        guard automaticEnabled, !requiresBackupConsent, !isWorking,
              now >= nextAutomaticAttempt, model.state == .ready,
              !model.isWorking, !model.isLifecycleMutationInProgress, !model.isJournalMutationInProgress else { return }
        do {
            let account = try await requireAccount()
            guard let bookID = account.bookID, try await model.cloudBackupBookID() == bookID else {
                pauseForBookReplacement()
                return
            }
            let revision = await (try model.requireStore()).changeRevision()
            if let lastRevision, lastRevision.generation == model.storeGeneration, lastRevision.revision == revision { return }
            if let lastSuccessfulBackup {
                let elapsed = now.timeIntervalSince(lastSuccessfulBackup)
                if elapsed >= 0 && elapsed < 300 { return }
            }
            nextAutomaticAttempt = now.addingTimeInterval(300)
            await backUpNow(model: model, automatic: true)
        } catch is CancellationError { return }
        catch { recordFailure(error, showAlert: false) }
    }

    private func requireAccount() async throws -> CloudBackupAccount {
        guard let account = try await vault.load(), account.configurationID == configuration.identity,
              !account.webToken.isEmpty else { throw CloudBackupError.reconnectRequired }
        return account
    }

    private func client(for account: CloudBackupAccount) -> CloudKitWebClient {
        let vault = vault
        return CloudKitWebClient(configuration: configuration, transport: transport,
            webToken: account.webToken, expectedUser: account.userRecordName) { token in
                try await vault.rotateToken(token, connectionID: account.connectionID)
            }
    }

    private func publish(_ account: CloudBackupAccount?) {
        isConnected = account != nil
        accountLabel = account?.label ?? ""
        automaticEnabled = (account?.automaticEnabled ?? false) && !requiresBackupConsent
        lastSuccessfulBackup = account?.lastSuccessfulBackup
        if !isWorking {
            phase = account == nil ? .disconnected
                : (automaticEnabled || account?.recoveryPassword == nil ? .connected : .paused)
        }
    }

    private func perform(phase: Phase, reportError: Bool = true,
        operation: @escaping @MainActor () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        self.phase = phase
        failureDetail = nil
        errorMessage = nil
        let operationEpoch = epoch
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await operation() }
            catch is CancellationError { if self.epoch == operationEpoch { self.phase = .waiting } }
            catch { if self.epoch == operationEpoch { self.recordFailure(error, showAlert: reportError) } }
        }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        work = nil
        isWorking = false
    }

    private func recordFailure(_ error: Error, showAlert: Bool) {
        let message = safeUserMessage(for: error, context: .exportData)
        failureDetail = message
        phase = .waiting
        if let cloud = error as? CloudBackupError {
            if cloud == .reconnectRequired || cloud == .accountChanged {
                phase = .reconnect
                automaticEnabled = false
                requiresBackupConsent = true
            }
            if case let .retryLater(delay) = cloud { nextAutomaticAttempt = Date().addingTimeInterval(delay) }
        }
        if showAlert { errorMessage = message }
    }
}
