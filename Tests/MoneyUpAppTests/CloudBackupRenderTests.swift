import SwiftUI
import UIKit
import XCTest
@testable import MoneyUp

final class CloudBackupRenderTests: XCTestCase {
    @MainActor
    func testRenderCloudConnectionAndRecoverySetup() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let configuration = try cloudBackupTestConfiguration()
        let server = TestCloudBackupServer()
        let vault = TestCloudBackupVault()
        let cloud = CloudBackupController(configuration: configuration, vault: vault,
            transport: server, outboxRoot: fixture.directoryURL)
        let model = fixture.model()
        for language in [AppLanguagePreference.english, .simplifiedChinese] {
            await capture(cloud: cloud, model: model, language: language, connected: false)
        }
        await vault.save(CloudBackupAccount(configurationID: configuration.identity,
            userRecordName: "user-A", webToken: "token-A", label: "Personal backup"))
        await cloud.loadStatus()
        for language in [AppLanguagePreference.english, .simplifiedChinese] {
            await capture(cloud: cloud, model: model, language: language, connected: true)
        }
        let requests = await server.capturedRequests()
        XCTAssertTrue(requests.isEmpty, "Rendering and loading local setup must not contact iCloud")
        await fixture.store.close()
    }

    @MainActor
    private func capture(cloud: CloudBackupController, model: AppModel,
        language: AppLanguagePreference, connected: Bool) async {
        let defaults = AppLanguagePreference.defaults
        let previous = defaults?.object(forKey: AppLanguagePreference.storageKey)
        defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppLanguagePreference.storageKey) }
            else { defaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        let view = NavigationStack {
            CloudBackupView(controller: cloud, onDownload: { _, _ in })
        }.environment(model).environment(\.locale, language.locale)
            .preferredColorScheme(connected ? .dark : .light)
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "cloud-\(connected ? "recovery-setup" : "connect")-\(language.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
