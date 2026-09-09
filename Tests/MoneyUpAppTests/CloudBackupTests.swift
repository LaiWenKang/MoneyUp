import Foundation
import MoneyUpCore
import MoneyUpPersistence
import XCTest
@testable import MoneyUp

final class CloudBackupTests: XCTestCase {
    private let password = "Synthetic recovery password"

    func testCallbackRequiresExactAssociatedDestinationAndOneBoundedToken() throws {
        let configuration = try cloudBackupTestConfiguration()
        let valid = try XCTUnwrap(URL(string: "https://moneyup.example/auth/icloud/callback?ckWebAuthToken=a%2Bb%2Fc%3D"))
        XCTAssertEqual(try configuration.token(from: valid), "a+b/c=")
        for raw in [
            "https://attacker.example/auth/icloud/callback?ckWebAuthToken=token",
            "https://moneyup.example/wrong?ckWebAuthToken=token",
            "http://moneyup.example/auth/icloud/callback?ckWebAuthToken=token",
            "https://moneyup.example/auth/icloud/callback?ckWebAuthToken=a&ckWebAuthToken=b",
            "https://moneyup.example/auth/icloud/callback?ckWebAuthToken=",
            "https://moneyup.example/auth/icloud/callback?ckWebAuthToken=token#fragment",
            "https://user@moneyup.example/auth/icloud/callback?ckWebAuthToken=token"
        ] { XCTAssertThrowsError(try configuration.token(from: XCTUnwrap(URL(string: raw)))) }
    }

    func testEndpointTrustRejectsLookalikesPlaintextAndArbitraryUploads() async throws {
        for raw in ["https://icloud.com.attacker.example/data", "http://upload.icloud-content.com/data",
            "https://upload.icloud-content.com:444/data", "https://attacker.example/data"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(CloudBackupConfiguration.isAppleAssetURL(url))
            XCTAssertFalse(CloudBackupConfiguration.isAppleSignInURL(url))
        }
        let transport = CloudBackupHTTPTransport()
        do {
            _ = try await transport.execute(URLRequest(url: XCTUnwrap(URL(string: "https://attacker.example/data"))), maximumResponseBytes: 100)
            XCTFail("Untrusted host must be rejected before starting a request")
        } catch CloudBackupError.invalidResponse {}
    }

    func testSessionTokensRotateDurablyBeforeTheNextRequest() async throws {
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        let signInURL = try await CloudKitWebClient(configuration: configuration, transport: server).signInURL()
        XCTAssertEqual(signInURL.host, "idmsa.apple.com")
        let account = CloudBackupAccount(configurationID: configuration.identity, userRecordName: "user-A", webToken: "token-A")
        let vault = TestCloudBackupVault(account)
        let client = client(configuration, server: server, vault: vault, account: account)
        _ = try await client.verifiedAccount()
        _ = try await client.listBackups()
        let stored = await vault.load()
        XCTAssertNotEqual(stored?.webToken, "token-A")
        let requests = await server.capturedRequests()
        let tokens = requests.compactMap { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
                .first { $0.name == "ckWebAuthToken" }?.value
        }
        XCTAssertEqual(Set(tokens).count, tokens.count)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.contains("/private/") == true })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == "https://moneyup.example" })
    }

    func testRotationStorageFailureStopsTheOperation() async throws {
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        let account = CloudBackupAccount(configurationID: configuration.identity, userRecordName: "user-A", webToken: "token-A")
        let vault = TestCloudBackupVault(account)
        await vault.setRotationFailure()
        do {
            _ = try await client(configuration, server: server, vault: vault, account: account).listBackups()
            XCTFail("A session that cannot be saved must not continue")
        } catch CloudBackupError.localStorage {}
        let requests = await server.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testAccountMismatchAndExpiredSessionCannotUpload() async throws {
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        let client = CloudKitWebClient(configuration: configuration, transport: server,
            webToken: "token-B", expectedUser: "user-A")
        do { _ = try await client.listBackups(); XCTFail("Account B must not inherit account A's approval") }
        catch CloudBackupError.accountChanged {}
        await server.expireSessions()
        do { _ = try await client.verifiedAccount(); XCTFail("Expired sessions require reconnection") }
        catch CloudBackupError.reconnectRequired {}
        let requests = await server.capturedRequests()
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasSuffix("/users/current") == true })
    }

    @MainActor
    func testEncryptedUploadDownloadAndReviewedRestorePreserveBookAndPendingDrafts() async throws {
        let source = try AppModelFixture()
        let destination = try AppModelFixture()
        defer { source.removeFiles(); destination.removeFiles() }
        let profile = UserProfile(baseCurrency: source.sgd)
        try await source.seed(profile: profile, accounts: [source.wallet, source.food])
        let capture = LockedCapture(kind: .income, amountText: "55", payee: "Unfinished private capture")
        let sourceModel = source.model(profile: profile,
            lockedCaptureStore: InMemoryLockedCaptureStore(captures: [capture]))
        _ = try await sourceModel.logExpense(amount: 19.90, accountID: source.wallet.id,
            categoryID: source.food.id, occurredAt: Date(), payee: "Private cafe", note: "Private note")
        let archiveURL = source.directoryURL.appendingPathComponent("source.moneyup")
        try await sourceModel.encryptedBackup(to: archiveURL, password: password)
        let manifest = try CloudBackupArchive.manifest(for: archiveURL, bookID: UUID())
        let server = TestCloudBackupServer()
        let client = CloudKitWebClient(configuration: try cloudBackupTestConfiguration(), transport: server,
            webToken: "token-B", expectedUser: "user-B")
        try await client.upload(manifest, archiveURL: archiveURL)
        let listed = try await client.listBackups()
        XCTAssertEqual(listed.backups, [manifest])
        let downloaded = destination.directoryURL.appendingPathComponent("downloaded.moneyup")
        try await client.download(manifest, to: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), try Data(contentsOf: archiveURL))
        let target = destination.model()
        target.profile = nil
        target.accounts = []
        target.state = .onboarding
        let ticket = try await target.prepareEncryptedRestorePreview(from: downloaded, password: password)
        try await target.restoreEncryptedBackup(ticket, password: password)
        XCTAssertEqual(target.entries.count, 1)
        XCTAssertEqual(target.entries.first?.payee, "Private cafe")
        XCTAssertEqual(target.profile?.baseCurrency, source.sgd)
        try await target.reviewPendingLockedCapturesForBackup()
        XCTAssertEqual(target.quickLogDraft?.sourceCaptureID, capture.id)
        let requests = await server.capturedRequests()
        for request in requests {
            let expectedOrigin = request.url?.host == "api.apple-cloudkit.com" ? "https://moneyup.example" : nil
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), expectedOrigin)
            let body = request.httpBody ?? Data()
            for secret in [password, "Private cafe", "Private note", "Unfinished private capture"] {
                XCTAssertNil(body.range(of: Data(secret.utf8)))
                XCTAssertFalse(request.url?.absoluteString.contains(secret) ?? false)
            }
        }
        await source.store.close()
        await destination.store.close()
    }

    func testInterruptedChunkUploadIsResumableAndNeverListsAnIncompleteBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudRetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try cloudBackupTestConfiguration()
        let bookID = UUID()
        let outbox = try CloudBackupOutbox(root: root, configurationID: configuration.identity,
            userRecordName: "user-A", bookID: bookID, recoveryContextID: UUID())
        try await outbox.prepareDirectory()
        let archive = await outbox.archiveURL
        try Data(repeating: 0x7c, count: CloudBackupManifest.chunkByteCount + 100).write(to: archive)
        let manifest = try await outbox.stage(bookID: bookID)
        let server = TestCloudBackupServer()
        await server.setFailChunk(1)
        let client = CloudKitWebClient(configuration: configuration, transport: server,
            webToken: "token-A", expectedUser: "user-A")
        do { try await client.upload(manifest, archiveURL: archive); XCTFail("Injected interruption must stop upload") }
        catch CloudBackupError.offline {}
        let incompleteCount = await server.manifestCount(for: "user-A")
        XCTAssertEqual(incompleteCount, 0)
        let pending = try await outbox.pending(bookID: bookID)
        XCTAssertEqual(pending, manifest)
        await server.setFailChunk(nil)
        try await client.upload(manifest, archiveURL: archive)
        try await client.upload(manifest, archiveURL: archive)
        let completeCount = await server.manifestCount(for: "user-A")
        let recordCount = await server.recordCount(for: "user-A")
        XCTAssertEqual(completeCount, 1)
        XCTAssertEqual(recordCount, manifest.chunks.count + 1)
        try await outbox.complete(manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testDamagedDownloadLeavesNoCandidateAndCannotOverwriteExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudDamage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("source.moneyup")
        try Data(repeating: 0x7c, count: 200).write(to: archive)
        let manifest = try CloudBackupArchive.manifest(for: archive, bookID: UUID())
        let server = TestCloudBackupServer()
        let client = CloudKitWebClient(configuration: try cloudBackupTestConfiguration(), transport: server,
            webToken: "token-A", expectedUser: "user-A")
        try await client.upload(manifest, archiveURL: archive)
        await server.setCorruptDownloads()
        let target = root.appendingPathComponent("candidate.moneyup")
        do { try await client.download(manifest, to: target); XCTFail("Corrupt data must fail before restore") }
        catch CloudBackupError.damagedBackup {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        do { try await client.download(manifest, to: archive); XCTFail("Existing files must never be overwritten") }
        catch CloudBackupError.localStorage {}
        XCTAssertEqual(try Data(contentsOf: archive), Data(repeating: 0x7c, count: 200))
    }

    func testOutboxCannotResumeAcrossRecoveryPasswordContexts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudKeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try cloudBackupTestConfiguration()
        let bookID = UUID()
        let original = try CloudBackupOutbox(root: root, configurationID: configuration.identity,
            userRecordName: "user-A", bookID: bookID, recoveryContextID: UUID())
        try await original.prepareDirectory()
        let originalURL = await original.archiveURL
        try Data(repeating: 0x7c, count: 128).write(to: originalURL)
        let manifest = try await original.stage(bookID: bookID)
        let replacement = try CloudBackupOutbox(root: root, configurationID: configuration.identity,
            userRecordName: "user-A", bookID: bookID, recoveryContextID: UUID())
        let pending = try await replacement.pending(bookID: bookID)
        XCTAssertNil(pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        let originalPending = try await original.pending(bookID: bookID)
        XCTAssertEqual(originalPending, manifest)
    }

    func testQuotaErrorDoesNotPublishARecoveryPoint() async throws {
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        await server.setQuotaExceeded()
        let client = CloudKitWebClient(configuration: configuration, transport: server,
            webToken: "token-A", expectedUser: "user-A")
        do { _ = try await client.listBackups(); XCTFail("Quota errors must remain actionable") }
        catch CloudBackupError.quotaExceeded {}
        let count = await server.manifestCount(for: "user-A")
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testAutomaticBackupMakesNoRequestsWithoutOptInOrForAnotherBook() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        let vault = TestCloudBackupVault()
        let controller = CloudBackupController(configuration: configuration, vault: vault,
            transport: server, outboxRoot: fixture.directoryURL)
        await controller.loadStatus()
        await controller.automaticTick(model: fixture.model(), now: Date())
        var account = CloudBackupAccount(configurationID: configuration.identity, userRecordName: "user-A", webToken: "token-A")
        account.bookID = UUID()
        account.recoveryPassword = password
        account.automaticEnabled = true
        await vault.save(account)
        await controller.loadStatus()
        await controller.automaticTick(model: fixture.model(), now: Date())
        let requests = await server.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(controller.automaticEnabled)
        await fixture.store.close()
    }

    @MainActor
    func testConnectingAnotherAccountDoesNotCarryBackupConsentOrPassword() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let configuration = try cloudBackupTestConfiguration()
        var previous = CloudBackupAccount(configurationID: configuration.identity, userRecordName: "user-A", webToken: "token-A")
        previous.bookID = UUID()
        previous.recoveryPassword = password
        previous.automaticEnabled = true
        let vault = TestCloudBackupVault(previous)
        let server = TestCloudBackupServer()
        let controller = CloudBackupController(configuration: configuration, vault: vault,
            transport: server, outboxRoot: fixture.directoryURL)
        await controller.connectAccount(using: TestCloudBackupSignIn(token: "token-B"), label: "Other account")
        let account = await vault.load()
        XCTAssertEqual(account?.userRecordName, "user-B")
        XCTAssertNil(account?.recoveryPassword)
        XCTAssertNil(account?.bookID)
        XCTAssertFalse(controller.automaticEnabled)
        let requests = await server.capturedRequests()
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasSuffix("/users/current") == true })
        await fixture.store.close()
    }

    @MainActor
    func testBackupIsSuccessfulOnlyAfterVerifiedDownloadAndRetryReusesTheSameArchive() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        await server.setCorruptDownloads()
        let vault = TestCloudBackupVault(CloudBackupAccount(configurationID: configuration.identity,
            userRecordName: "user-A", webToken: "token-A"))
        let controller = CloudBackupController(configuration: configuration, vault: vault,
            transport: server, outboxRoot: fixture.directoryURL)
        await controller.enableBackup(model: model, password: password, confirmation: password,
            savedRecoveryPassword: true)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.lastSuccessfulBackup)
        let failedAccount = await vault.load()
        XCTAssertNil(failedAccount?.lastSuccessfulBackup)
        let uploadedCount = await server.manifestCount(for: "user-A")
        XCTAssertEqual(uploadedCount, 1, "Upload alone must not be reported as verified recovery")

        await server.setCorruptDownloads(false)
        await controller.backUpNow(model: model)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.lastSuccessfulBackup)
        let retriedCount = await server.manifestCount(for: "user-A")
        XCTAssertEqual(retriedCount, uploadedCount, "Retry verifies the retained archive without duplicating it")
        XCTAssertEqual(controller.phase, .backedUp)
        await fixture.store.close()
    }

    @MainActor
    func testEnableBackupUsesRecoveryPasswordAndOnlyBacksUpChanges() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        let vault = TestCloudBackupVault(CloudBackupAccount(configurationID: configuration.identity,
            userRecordName: "user-A", webToken: "token-A"))
        let controller = CloudBackupController(configuration: configuration, vault: vault,
            transport: server, outboxRoot: fixture.directoryURL)
        await controller.enableBackup(model: model, password: password, confirmation: password, savedRecoveryPassword: true)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.automaticEnabled)
        XCTAssertNotNil(controller.lastSuccessfulBackup)
        let originalCount = await server.manifestCount(for: "user-A")
        await controller.automaticTick(model: model, now: Date().addingTimeInterval(301))
        let unchangedCount = await server.manifestCount(for: "user-A")
        XCTAssertEqual(unchangedCount, originalCount)
        _ = try await model.logExpense(amount: 10, accountID: fixture.wallet.id,
            categoryID: fixture.food.id, occurredAt: Date(), payee: nil, note: nil)
        await controller.automaticTick(model: model, now: Date().addingTimeInterval(601))
        let changedCount = await server.manifestCount(for: "user-A")
        XCTAssertEqual(changedCount, originalCount + 1)
        await controller.pauseAutomatic()
        XCTAssertFalse(controller.automaticEnabled)
        await fixture.store.close()
    }

    private func client(_ configuration: CloudBackupConfiguration, server: TestCloudBackupServer,
        vault: TestCloudBackupVault, account: CloudBackupAccount) -> CloudKitWebClient {
        CloudKitWebClient(configuration: configuration, transport: server,
            webToken: account.webToken, expectedUser: account.userRecordName) { token in
                try await vault.rotateToken(token, connectionID: account.connectionID)
            }
    }
}
