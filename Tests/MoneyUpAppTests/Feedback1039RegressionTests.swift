import Foundation
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

final class Feedback1039RegressionTests: XCTestCase {
    @MainActor
    func testSelectedChipExpandsHorizontallyEvenInsideAnIconOnlyContainer() {
        for language in ["en", "zh-Hans"] {
            let selected = chipSize(selected: true, language: language)
            let collapsed = chipSize(selected: false, language: language)
            XCTAssertGreaterThan(selected.width, collapsed.width + 12)
            XCTAssertEqual(selected.height, collapsed.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual(collapsed.width, 44)
            XCTAssertGreaterThanOrEqual(collapsed.height, 44)
            XCTAssertLessThanOrEqual(selected.height, 48)
        }
    }

    @MainActor
    func testHistoryScopeFitsSmallPhoneWithoutVerticalExpansion() {
        for scope in HistoryQuickRange.allCases {
            let view = HistoryScopeSelector(selection: .constant(scope))
                .environment(\.dynamicTypeSize, .large)
                .labelStyle(.iconOnly)
            let host = UIHostingController(rootView: view)
            let size = host.sizeThatFits(in: CGSize(width: 288, height: 1_000))
            XCTAssertLessThanOrEqual(size.height, 60, "\(scope) must remain a horizontal row")
        }
    }

    func testUnavailableWidgetSummaryStillOffersCaptureWithoutInventingData() {
        XCTAssertTrue(BudgetWidgetSnapshot.disabled.usesQuickActionFallback)
        XCTAssertTrue(BudgetWidgetSnapshot.stale.usesQuickActionFallback)
        let expiry = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let current: [BudgetWidgetSnapshot] = [
            .available(percentUsed: 72, validUntil: expiry),
            .needsBudget(validUntil: expiry), .zeroBudget(validUntil: expiry),
            .negativeBudget(validUntil: expiry)
        ]
        for snapshot in current { XCTAssertFalse(snapshot.usesQuickActionFallback) }
        for action in MoneyUpQuickAction.allCases {
            XCTAssertEqual(MoneyUpQuickAction(exactDeepLink: action.deepLink), action)
            let injected = URL(string: action.deepLink.absoluteString + "?amount=100")!
            XCTAssertNil(MoneyUpQuickAction(exactDeepLink: injected))
        }
    }

    @MainActor
    func testDraftProtectionBlocksSwipeOnlyForEditsOrAnActiveSave() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        for (changed, saving) in [(false, false), (true, false), (false, true)] {
            let editor = UIHostingController(rootView: NavigationStack {
                Text("Draft")
                    .moneyUpProtectDraft(hasChanges: changed, isSaving: saving)
            })
            presenter.present(editor, animated: false)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(editor.isModalInPresentation, changed || saving)
            presenter.dismiss(animated: false)
        }
    }

    @MainActor
    private func chipSize(selected: Bool, language: String) -> CGSize {
        let host = UIHostingController(rootView:
            MoneyUpSectionChip(title: "history.scope.today", systemImage: "sun.max.fill", isSelected: selected) {}
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, .large)
                .labelStyle(.iconOnly)
        )
        return host.sizeThatFits(in: CGSize(width: 320, height: 1_000))
    }
}
