import Foundation
import MoneyUpCore
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

/// Runs the real SwiftUI amount binding against UIKit's editable field. Device
/// touch, safe-area occlusion and VoiceOver acceptance remain separate gates.
final class QuickLogKeyboardJourneyTests: XCTestCase {
    @MainActor
    func testFreshFocusDecimalKeystrokesAndKeyboardDismissalPreserveDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date(timeIntervalSince1970: 1_783_411_200)
        let profile = UserProfile(baseCurrency: fixture.sgd, preferredAccountID: fixture.wallet.id)
        let model = fixture.model(profile: profile, currentDate: { now })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let priorKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: QuickLogEntryView(
            kind: .constant(.expense), dismissAfterSave: false, isActive: true,
            launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in }
        ).environment(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            MoneyUpKeyboard.dismiss()
            window.isHidden = true
            window.rootViewController = nil
            priorKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        for _ in 0..<100 {
            if fields(in: host.view).contains(where: { $0.isFirstResponder }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let amount = try XCTUnwrap(fields(in: host.view).first { $0.isFirstResponder })
        XCTAssertEqual(amount.keyboardType, .decimalPad)
        for (key, expected) in [("1", "1"), ("2", "12"), (".", "12."), ("0", "12.0"), ("0", "12.00")] {
            amount.insertText(key)
            await Task.yield()
            XCTAssertEqual(amount.text, expected)
            XCTAssertEqual(model.quickLogDraft?.amountText, expected)
        }
        XCTAssertEqual(model.quickLogDraft?.occurredAt, now)
        XCTAssertEqual(model.quickLogDraft?.accountID, fixture.wallet.id)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "quick-log-amount-keyboard"
        attachment.lifetime = .keepAlways
        add(attachment)
        let draft = model.quickLogDraft
        MoneyUpKeyboard.dismiss()
        for _ in 0..<50 {
            if !amount.isFirstResponder { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(amount.isFirstResponder)
        XCTAssertEqual(model.quickLogDraft, draft)
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }

    @MainActor
    private func fields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
}
