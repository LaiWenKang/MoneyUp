import Foundation
import MoneyUpCore
@testable import MoneyUp
import XCTest

final class LedgerExportPreparationTests: XCTestCase {
    @MainActor
    func testBothFormatsRenderOffMainAndPreserveExactOutput() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entries = [try fixture.expense(amount: Decimal(string: "12.50")!)]
        let model = fixture.model(entries: entries)
        let snapshot = LedgerExportSnapshot(entries: entries, accounts: model.accounts,
            rates: model.exchangeRates, attachments: model.receiptAttachmentMetadata)
        let csv = try await model.csvExport { snapshot in
            XCTAssertFalse(Thread.isMainThread)
            return snapshot.csv()
        }
        let xlsx = try await model.xlsxExport { snapshot in
            XCTAssertFalse(Thread.isMainThread)
            return snapshot.xlsx()
        }
        XCTAssertEqual(csv, snapshot.csv())
        XCTAssertEqual(xlsx, snapshot.xlsx())
        XCTAssertFalse(model.isJournalMutationInProgress)
        XCTAssertEqual(model.entries, entries)
        await fixture.store.close()
    }

    @MainActor
    func testLockDuringRenderingWithholdsPlaintextAndDrainsMutation() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let gate = ExportRenderingGate()
        let task = Task { try await model.csvExport(renderer: gate.render) }
        try await waitForStart(gate)
        XCTAssertTrue(model.isJournalMutationInProgress)
        do { _ = try await model.xlsxExport(); XCTFail("Concurrent export must be rejected") }
        catch AppModelError.transactionInProgress {}
        model.lockManually()
        gate.release()
        do { _ = try await task.value; XCTFail("Locked export must not publish plaintext") }
        catch AppModelError.locked {}
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.isJournalMutationInProgress)
        await model.waitForPendingStoreClose()
    }

    @MainActor
    func testCancellationDiscardsLateResultWithoutLeavingBusyState() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let gate = ExportRenderingGate()
        let task = Task { try await model.csvExport(renderer: gate.render) }
        try await waitForStart(gate)
        task.cancel()
        gate.release()
        do { _ = try await task.value; XCTFail("Cancelled export must discard its result") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(model.isJournalMutationInProgress)
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    @MainActor
    func testChangedLogicalBookRejectsAnOldExport() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let gate = ExportRenderingGate()
        let task = Task { try await model.csvExport(renderer: gate.render) }
        try await waitForStart(gate)
        model.logicalBookRevision &+= 1
        gate.release()
        do { _ = try await task.value; XCTFail("Old-book result must be rejected") }
        catch AppModelError.locked {}
        XCTAssertFalse(model.isJournalMutationInProgress)
        await fixture.store.close()
    }

    @MainActor
    func testRendererFailureAllowsASubsequentExport() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        do {
            _ = try await model.xlsxExport { _ in throw ExportTestError.rendererFailed }
            XCTFail("Renderer failure must propagate")
        } catch { XCTAssertEqual(error as? ExportTestError, .rendererFailed) }
        XCTAssertFalse(model.isJournalMutationInProgress)
        let recovered = try await model.csvExport()
        XCTAssertFalse(recovered.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    private func waitForStart(_ gate: ExportRenderingGate) async throws {
        for _ in 0..<100 {
            if gate.started { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        gate.release()
        XCTFail("Rendering must start without blocking the main actor")
        throw ExportTestError.rendererFailed
    }
}

private enum ExportTestError: Error, Equatable { case rendererFailed }

private final class ExportRenderingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    var started: Bool { lock.withLock { didStart } }

    func render(_ snapshot: LedgerExportSnapshot) throws -> String {
        XCTAssertFalse(Thread.isMainThread)
        lock.withLock { didStart = true }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw ExportTestError.rendererFailed
        }
        return snapshot.csv()
    }

    func release() { semaphore.signal() }
}
