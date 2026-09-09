import Foundation
import MoneyUpCore
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

final class QuickLogSmartEntryRenderTests: XCTestCase {
    @MainActor
    func testSmartEntryLayoutInEnglishChineseAndLargeText() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let priorWindow = scene.windows.first { $0.isKeyWindow }
        defer {
            MoneyUpKeyboard.dismiss()
            window.isHidden = true
            window.rootViewController = nil
            priorWindow?.makeKey()
        }
        let scenarios: [(String, CGFloat, DynamicTypeSize)] = [
            ("en", 390, .large), ("zh-Hans", 320, .large), ("en", 390, .accessibility2)
        ]
        for (index, scenario) in scenarios.enumerated() {
            window.frame = CGRect(x: 0, y: 0, width: scenario.1, height: 844)
            let view = QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false, isActive: false,
                launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in })
                .environment(model)
                .environment(\.locale, Locale(identifier: scenario.0))
                .environment(\.dynamicTypeSize, scenario.2)
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(500))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "smart-entry-layout-\(index)-\(scenario.0)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(model.entries.count, 0)
            XCTAssertTrue(model.quickLogDraft?.amountText.isEmpty ?? true)
        }
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }
}
