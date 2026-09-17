import Foundation
import MoneyUpCore
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

final class EntryCatalogRenderTests: XCTestCase {
    @MainActor
    func testCatalogueRendersWithoutCreatingOrEnablingLegacyRecords() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let original = [fixture.wallet, fixture.usAccount, fixture.food]
        try await fixture.seed(profile: profile, accounts: original)
        let model = fixture.model(profile: profile, accounts: original)
        let defaults = try XCTUnwrap(AppLanguagePreference.defaults)
        let originalLanguage = defaults.string(forKey: AppLanguagePreference.storageKey)
        defer {
            if let originalLanguage { defaults.set(originalLanguage, forKey: AppLanguagePreference.storageKey) }
            else { defaults.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        for scope in LedgerPresetScope.allCases {
            for language in ["en", "zh-Hans"] {
                defaults.set(language, forKey: AppLanguagePreference.storageKey)
                for size in [DynamicTypeSize.large, .accessibility2] {
                    let scheme: ColorScheme = size.isAccessibilitySize ? .dark : .light
                    let host = UIHostingController(rootView: NavigationStack {
                        EntryCatalogView(scope: scope, showsDone: true)
                    }.environment(model).environment(\.locale, Locale(identifier: language))
                        .environment(\.dynamicTypeSize, size).preferredColorScheme(scheme))
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    host.view.frame = window.bounds
                    try await Task.sleep(for: .milliseconds(350))
                    host.view.layoutIfNeeded()
                    XCTAssertEqual(model.accounts, original)
                    XCTAssertTrue(model.accounts.allSatisfy { $0.presetID == nil && !$0.isHiddenFromEntry })
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "entry-catalog-\(scope.rawValue)-\(language)-\(size.isAccessibilitySize ? "large" : "normal")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        let stored = try await fixture.store.fetchAll(LedgerAccount.self, from: .accounts)
        XCTAssertEqual(Set(stored.map(\.id)), Set(original.map(\.id)))
        XCTAssertTrue(model.budgetNodes.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testPresetSymbolsExistOnTheRunningPlatform() {
        for preset in LedgerPresetCatalog.accounts + LedgerPresetCatalog.expenses {
            XCTAssertNotNil(UIImage(systemName: preset.symbol), preset.symbol)
        }
    }
}
