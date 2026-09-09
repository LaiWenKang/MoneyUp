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
            amount.sendActions(for: .editingChanged)
            // UIKit programmatic insertion and SwiftUI's binding publication
            // can span a render turn; wait for the observable result, not just
            // one executor yield (which need not run a UI transaction).
            for _ in 0..<20 {
                if model.quickLogDraft?.amountText == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(50))
            if let selection = amount.selectedTextRange {
                XCTAssertEqual(amount.offset(from: amount.beginningOfDocument, to: selection.start), expected.count, "Cursor must stay after the typed amount")
            }
            XCTAssertNotNil(amount.window, "Validation must not detach the focused input")
            XCTAssertTrue(amount.isFirstResponder)
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
    func testChineseMarkedTextAndFocusSurviveAnUnrelatedDraftRerender() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let request = QuickLogRouteRequest(id: 1, ingressToken: UUID(), requiresIngressAcknowledgement: false,
            generation: 0, mode: .smartEntry)
        let host = UIHostingController(rootView: QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false,
            isActive: true, launchRequest: request, onRequestHandled: { _ in }, onNavigate: { _ in }).environment(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { MoneyUpKeyboard.dismiss(); window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
        for _ in 0..<100 {
            if views(host.view).contains(where: { $0.isFirstResponder && $0 is any UITextInput }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try XCTUnwrap(views(host.view).first { $0.isFirstResponder && $0 is any UITextInput })
        let input = try XCTUnwrap(view as? any UITextInput)
        input.setMarkedText("shou ru", selectedRange: NSRange(location: 7, length: 0))
        XCTAssertTrue(MoneyUpKeyboard.hasMarkedText(in: host.view))
        try await model.updateMerchantSuggestions(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(view.isFirstResponder)
        let range = try XCTUnwrap(input.markedTextRange)
        XCTAssertEqual(input.text(in: range), "shou ru")
        XCTAssertTrue(model.entries.isEmpty)
        input.setMarkedText("收入", selectedRange: NSRange(location: 2, length: 0))
        input.unmarkText()
        (view as? UIControl)?.sendActions(for: .editingChanged)
        if let textView = view as? UITextView { textView.delegate?.textViewDidChange?(textView) }
        for _ in 0..<50 {
            if model.quickLogDraft?.smartText == "收入" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.quickLogDraft?.smartText, "收入")
        XCTAssertNil(input.markedTextRange)
        XCTAssertTrue(view.isFirstResponder)
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }

    @MainActor
    private func fields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
}
