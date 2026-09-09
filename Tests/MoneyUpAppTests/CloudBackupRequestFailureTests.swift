import Foundation
import XCTest
@testable import MoneyUp

final class CloudBackupRequestFailureTests: XCTestCase {
    @MainActor
    func testRejectedSaveKeepsAccountAndArchiveUntilManualRetrySucceeds() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        await server.setModifyError("BAD_REQUEST")
        let vault = TestCloudBackupVault(CloudBackupAccount(configurationID: configuration.identity,
            userRecordName: "user-A", webToken: "token-A"))
        let controller = CloudBackupController(configuration: configuration, vault: vault,
            transport: server, outboxRoot: fixture.directoryURL)
        let password = "Synthetic recovery password"
        await controller.enableBackup(model: model, password: password, confirmation: password,
            savedRecoveryPassword: true)

        XCTAssertEqual(controller.phase, .attention)
        XCTAssertTrue(controller.isConnected)
        XCTAssertTrue(controller.automaticEnabled)
        XCTAssertNil(controller.lastSuccessfulBackup)
        XCTAssertEqual(controller.errorMessage, CloudBackupError.requestRejected.localizedDescription)
        await controller.loadStatus()
        XCTAssertEqual(controller.phase, .attention, "Reopening settings must retain the actionable status")
        let saved = await vault.load()
        let account = try XCTUnwrap(saved)
        XCTAssertEqual(account.recoveryPassword, password)
        XCTAssertNotEqual(account.webToken, "token-A", "A rejected request can still rotate the session")
        let outbox = try CloudBackupOutbox(root: fixture.directoryURL, configurationID: configuration.identity,
            userRecordName: account.userRecordName, bookID: XCTUnwrap(account.bookID),
            recoveryContextID: XCTUnwrap(account.recoveryContextID))
        let staged = try await outbox.pending(bookID: XCTUnwrap(account.bookID))
        let manifest = try XCTUnwrap(staged)
        let archiveURL = await outbox.archiveURL
        let original = try Data(contentsOf: archiveURL)
        let requests = await server.capturedRequests()
        await controller.automaticTick(model: model, now: Date().addingTimeInterval(3_600))
        let afterTick = await server.capturedRequests()
        XCTAssertEqual(afterTick.count, requests.count, "Permanent rejection must not loop automatically")
        XCTAssertEqual(try Data(contentsOf: archiveURL), original)

        await server.setModifyError(nil)
        await controller.backUpNow(model: model)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.phase, .backedUp)
        XCTAssertNotNil(controller.lastSuccessfulBackup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        await controller.listBackups()
        XCTAssertEqual(controller.backups, [manifest], "Retry must retain the original recovery-point identity")
        await server.setModifyError("BAD_REQUEST")
        await controller.backUpNow(model: model)
        XCTAssertEqual(controller.phase, .attention)
        await controller.pauseAutomatic()
        await controller.loadStatus()
        XCTAssertEqual(controller.phase, .paused, "Explicit pause takes precedence over a previous rejection")
        XCTAssertFalse(controller.automaticEnabled)
        XCTAssertTrue(model.entries.isEmpty)
        await fixture.store.close()
    }

    func testTopLevelAndPerRecordRejectionsUseTheSameSafeMessage() async throws {
        for perRecord in [false, true] {
            let error = CloudBackupJSON.object([
                "recordName": .string("synthetic-record"), "serverErrorCode": .string("BAD_REQUEST"),
                "reason": .string("Private token, account, path, and record content"),
                "redirectURL": .string("https://untrusted.example/?secret=private")])
            let body = perRecord ? CloudBackupJSON.object(["records": .array([error])]) : error
            let transport = FixedCloudResponse(status: perRecord ? 200 : 400, body: body)
            let client = CloudKitWebClient(configuration: try cloudBackupTestConfiguration(), transport: transport,
                webToken: "synthetic-token")
            do {
                try await client.create(recordName: "synthetic-record", recordType: "MoneyUpBackupChunk", fields: [:])
                XCTFail("Rejected records must never report success")
            } catch let failure as CloudBackupError {
                XCTAssertEqual(failure, .requestRejected)
                XCTAssertFalse(safeUserMessage(for: failure).contains("Private"))
                XCTAssertFalse(safeUserMessage(for: failure).contains("untrusted.example"))
            }
        }
    }

    func testTemporaryServerFailureRemainsRetryable() throws {
        for code in ["INTERNAL_ERROR", "THROTTLED", "TRY_AGAIN_LATER", "SERVICE_UNAVAILABLE"] {
            XCTAssertThrowsError(try CloudKitWebClient.checkError(.object([
                "serverErrorCode": .string(code), "retryAfter": .integer(120)]))) {
                XCTAssertEqual($0 as? CloudBackupError, .retryLater(120))
            }
        }
    }

    func testInvalidServiceResponseDoesNotMasqueradeAsSignInFailure() async throws {
        let transport = FixedCloudResponse(status: 200, body: .object([:]))
        let client = CloudKitWebClient(configuration: try cloudBackupTestConfiguration(), transport: transport,
            webToken: "synthetic-token")
        do {
            _ = try await client.verifiedAccount()
            XCTFail("A successful HTTP status alone does not verify an account")
        } catch let failure as CloudBackupError {
            XCTAssertEqual(failure, .invalidResponse)
            XCTAssertNotEqual(failure.localizedDescription, CloudBackupError.invalidCallback.localizedDescription)
        }
    }
}

private struct FixedCloudResponse: CloudBackupHTTPTransporting {
    let status: Int
    let body: CloudBackupJSON

    func execute(_ request: URLRequest, maximumResponseBytes: Int) throws -> CloudBackupHTTPResponse {
        CloudBackupHTTPResponse(status: status, headers: [:], data: try JSONEncoder().encode(body))
    }
}
