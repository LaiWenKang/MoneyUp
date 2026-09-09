import SwiftUI
import UIKit
import XCTest
@testable import MoneyUp

final class CloudBackupRenderTests: XCTestCase {
    @MainActor
    func testRenderInternalBetaCloudConnection() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let configuration = try CloudBackupConfiguration(container: "iCloud.example.MoneyUp",
            environment: .production, apiToken: "synthetic-token",
            callbackURL: XCTUnwrap(URL(string: "https://moneyup.example/auth/icloud/callback")), isInternalBeta: true)
        let server = TestCloudBackupServer()
        let cloud = CloudBackupController(configuration: configuration, vault: TestCloudBackupVault(),
            transport: server, outboxRoot: fixture.directoryURL)
        for language in [AppLanguagePreference.english, .simplifiedChinese] {
            await capture(cloud: cloud, model: fixture.model(), language: language, connected: false)
        }
        let requests = await server.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testRenderDataSafetyWithCloudBackupUnavailable() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        model.cloudBackupController = nil
        let defaults = AppLanguagePreference.defaults
        let previous = defaults?.object(forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppLanguagePreference.storageKey) }
            else { defaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        for language in [AppLanguagePreference.english, .simplifiedChinese] {
            defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
            let host = UIHostingController(rootView: NavigationStack { DataSafetyView() }
                .environment(model).environment(\.locale, language.locale))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = "data-safety-cloud-unavailable-\(language.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        await fixture.store.close()
    }

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
        attachment.name = "cloud-\(cloud.configuration.isInternalBeta ? "beta-" : "")\(connected ? "recovery-setup" : "connect")-\(language.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
