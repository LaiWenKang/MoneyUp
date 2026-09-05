import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import XCTest

/// Generates inspectable native UI evidence on the CI simulator. Attachments
/// are reviewed visually; this is not a claim of automated accessibility QA.
final class RedesignRenderEvidenceTests: XCTestCase {
    @MainActor
    func testRenderBudgetAndCategoryReviewEvidence() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date()
        let child = LedgerAccount(name: "Groceries", kind: .expense, parentID: fixture.food.id)
        let dining = LedgerAccount(name: "Dining", kind: .expense, parentID: fixture.food.id)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, child, dining]
        let nodes = [
            BudgetNode(id: fixture.food.id, name: "Food", limit: try Money(100, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic),
            BudgetNode(id: child.id, parentID: fixture.food.id, name: child.name, limit: try Money(300, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic),
            BudgetNode(id: dining.id, parentID: fixture.food.id, name: dining.name, limit: try Money(200, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic)
        ]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        try await fixture.seed(profile: profile, accounts: accounts, budgetNodes: nodes)
        let model = fixture.model(profile: profile, accounts: accounts, budgetNodes: nodes, currentDate: { now })
        _ = try XCTUnwrap(model.budgetProgressThisMonthResult().value)
        await capture(PlanView().environment(model).preferredColorScheme(.light), name: "budget-light")
        await capture(PlanView().environment(model).preferredColorScheme(.dark), name: "budget-dark")
        await capture(CategoryManagementList().environment(model).preferredColorScheme(.light), name: "categories-light")
        await capture(NavigationStack { DisplaySettingsView() }.environment(model).environment(\.dynamicTypeSize, .accessibility2).preferredColorScheme(.dark), name: "display-large-text")
        await fixture.store.close()
    }

    @MainActor
    private func capture<Content: View>(_ content: Content, name: String) async {
        let controller = UIHostingController(rootView: content)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
