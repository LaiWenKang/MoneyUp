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
        let previousPrivacy = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previousPrivacy { UserDefaults.standard.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date()
        let child = LedgerAccount(name: "Groceries", kind: .expense, parentID: fixture.food.id)
        let dining = LedgerAccount(name: "Dining", kind: .expense, parentID: fixture.food.id)
        let transport = LedgerAccount(name: "Transport", kind: .expense)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, child, dining, transport]
        let nodes = [
            BudgetNode(id: fixture.food.id, name: "Food", limit: try Money(100, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic),
            BudgetNode(id: child.id, parentID: fixture.food.id, name: child.name, limit: try Money(300, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic),
            BudgetNode(id: dining.id, parentID: fixture.food.id, name: dining.name, limit: try Money(200, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic),
            BudgetNode(id: transport.id, name: transport.name, limit: try Money(200, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic)
        ]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        let entries = [try fixture.expense(amount: Decimal(string: "48.50")!, occurredAt: now, payee: "Neighbourhood café")]
        let allowance = try AllowancePlan(
            name: "Meal benefit", amount: Money(15, currency: fixture.sgd), cadence: .daily,
            fundingMode: .benefitLimit, startsAt: Calendar.current.startOfDay(for: now),
            timeZoneIdentifier: "GMT", eligibleCategoryIDs: [fixture.food.id]
        )
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes, allowancePlans: [allowance])
        let model = fixture.model(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes, allowancePlans: [allowance], currentDate: { now })
        let progress = try XCTUnwrap(model.budgetProgressThisMonthResult().value)
        await capture(PlanView().environment(model).preferredColorScheme(.light), name: "budget-light")
        await capture(PlanView().environment(model).preferredColorScheme(.dark), name: "budget-dark")
        await capture(CategoryManagementList().environment(model).preferredColorScheme(.light), name: "categories-light")
        await capture(NavigationStack { DisplaySettingsView() }.environment(model).environment(\.dynamicTypeSize, .accessibility2).preferredColorScheme(.dark), name: "display-large-text")
        await capture(BudgetCompositionView(progress: progress, onEdit: { _ in }).padding(24).background(Color.moneyUpBackground).ignoresSafeArea().preferredColorScheme(.light), name: "composition-detail", height: 280)
        await capture(PlanView(initialSection: .calendar).environment(model).preferredColorScheme(.dark), name: "calendar-dark")
        await capture(NavigationStack { HistoryView() }.environment(model).preferredColorScheme(.dark), name: "history-dark")
        await capture(DashboardView().environment(model).preferredColorScheme(.dark), name: "today-dark")
        await capture(AssetsView().environment(model).preferredColorScheme(.light), name: "assets-light")
        await capture(PlanView().environment(model).environment(\.dynamicTypeSize, .accessibility2).preferredColorScheme(.dark), name: "budget-large-text", height: 900, width: 390)
        await capture(PlanView().environment(model).environment(\.locale, Locale(identifier: "zh-Hans")).preferredColorScheme(.light), name: "budget-small-chinese", height: 740, width: 320)
        await capture(NavigationStack { HistoryView() }.environment(model).environment(\.dynamicTypeSize, .accessibility2).preferredColorScheme(.light), name: "history-large-text", height: 900)
        await fixture.store.close()
    }

    @MainActor
    private func capture<Content: View>(_ content: Content, name: String, height: CGFloat = 844, width: CGFloat = 390) async {
        let controller = UIHostingController(rootView: content)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        }
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
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
