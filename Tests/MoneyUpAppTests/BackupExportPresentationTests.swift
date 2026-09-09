import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import MoneyUp

final class BackupExportPresentationTests: XCTestCase {
    func testTransferSuppliesFilenameBeforeTheSaveDialogIsCreated() throws {
        guard #available(iOS 18.2, *) else { throw XCTSkip("Transferable metadata inspection requires iOS 18.2") }
        let transfer = MoneyUpArchiveTransfer(fileURL: URL(fileURLWithPath: "/tmp/synthetic.moneyup"))
        XCTAssertEqual(transfer.suggestedFilename, "MoneyUp-Backup.moneyup")
    }

    @MainActor
    func testInventoryThenEncryptedBackupPresentsFilesPickerRepeatedly() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food])
        let model = fixture.model(profile: profile)
        _ = try await model.privacySafeDataInventory()
        let archiveURL = fixture.directoryURL.appendingPathComponent("export-fixture.moneyup")
        let password = "Synthetic export password"
        try await model.encryptedBackup(to: archiveURL, password: password)
        let original = try Data(contentsOf: archiveURL)
        let snapshot = try PortableArchive.open(original, password: password)
        XCTAssertFalse(snapshot.records.isEmpty)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = BackupExportProbeState()
        let host = UIHostingController(rootView: BackupExportProbe(
            transfer: MoneyUpArchiveTransfer(fileURL: archiveURL), state: state
        ))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()

        for _ in 0..<2 {
            state.isPresented = true
            for _ in 0..<200 {
                if let picker = host.presentedViewController as? UIDocumentPickerViewController,
                   !picker.isBeingPresented, picker.view.window != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let picker = try XCTUnwrap(host.presentedViewController as? UIDocumentPickerViewController,
                "The real SwiftUI Transferable bridge must present Files without a filename exception")
            XCTAssertFalse(picker.isBeingPresented)
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = "encrypted-backup-files-picker"
            attachment.lifetime = .keepAlways
            add(attachment)
            state.isPresented = false
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try Data(contentsOf: archiveURL), original,
            "Presenting or dismissing the picker must not consume or rewrite the encrypted backup")
        if #available(iOS 18.2, *) {
            let destination = fixture.directoryURL.appendingPathComponent("exported", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let exported = try await MoneyUpArchiveTransfer(fileURL: archiveURL)
                .export(to: destination, contentType: .moneyUpArchive)
            // The filename is a suggestion; a receiver may retain the source
            // basename. The archive type and encrypted bytes must survive.
            XCTAssertEqual(exported.pathExtension, "moneyup")
            XCTAssertEqual(try Data(contentsOf: exported), original)
        }
        await fixture.store.close()
    }
}

@MainActor @Observable
private final class BackupExportProbeState {
    var isPresented = false
}

private struct BackupExportProbe: View {
    let transfer: MoneyUpArchiveTransfer
    @Bindable var state: BackupExportProbeState

    var body: some View {
        Text("Encrypted backup export regression")
            .fileExporter(isPresented: $state.isPresented, item: transfer,
                contentTypes: [.moneyUpArchive], defaultFilename: "MoneyUp-Backup.moneyup") { _ in }
    }
}
