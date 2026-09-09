import Foundation
import MoneyUpCore
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

/// Runs on actual simulator scene bounds. Simulator model labels describe
/// layout/configuration coverage; virtual CPUs cannot measure phone hardware.
final class BatchDeviceCoverageTests: XCTestCase {
    @MainActor
    func testBatchReviewOnThisDevice() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = try await BatchReviewTestSupport.start(fixture)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let oldPrivacy = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            window.isHidden = true; window.rootViewController = nil; prior?.makeKey()
            if let oldPrivacy { UserDefaults.standard.set(oldPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        let scenarios: [(String, DynamicTypeSize)] = [("en", .large), ("zh-Hans", .large), ("en", .accessibility2)]
        for (index, scenario) in scenarios.enumerated() {
            let host = UIHostingController(rootView: BatchDeviceRoot(model: model)
                .environment(\.locale, Locale(identifier: scenario.0)).environment(\.dynamicTypeSize, scenario.1))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "batch-device-\(index)-\(scenario.0)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(model.quickLogDraft?.batch?.items.count, 3)
            XCTAssertTrue(model.entries.isEmpty)
        }
        let start = ContinuousClock.now
        _ = try await BatchReviewTestSupport.saveCurrent(model)
        let elapsed = start.duration(to: .now)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.quickLogDraft?.batch?.items.count, 2)
        XCTAssertEqual(model.quickLogDraft?.kind, .refund)
        XCTAssertEqual(model.entries.count, 1)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let metrics: [String: Any] = ["simulated": true, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown",
            "widthPoints": window.bounds.width, "heightPoints": window.bounds.height,
            "saveSeconds": seconds, "scope": "One synthetic save including model publication; not physical-device timing"]
        let metricAttachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        metricAttachment.name = "batch-device-metrics"
        metricAttachment.lifetime = .keepAlways
        add(metricAttachment)
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }
}

private struct BatchDeviceRoot: View {
    let model: AppModel
    @State private var kind: QuickLogKind = .expense
    var body: some View {
        QuickLogEntryView(kind: $kind, dismissAfterSave: false, isActive: false,
            launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in }).environment(model)
    }
}
