import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import XCTest

/// Secondary screens rendered for the 1059.1 visual audit. Hosting-controller
/// roots over synthetic data; not device screenshots.
final class Feedback1059AuditRenderTests: XCTestCase {
    @MainActor
    func testRenderSecondaryScreensForAudit() async throws {
        let fixture = try IntelligenceAppFixture()
        defer { fixture.removeFiles() }
        let previousPrivacy = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previousPrivacy { UserDefaults.standard.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        let profile = fixture.profile()
        let dates = fixture.weeklyDates
        let entries = try fixture.expenses(dates: dates, amount: 8, payee: "Weekly Cafe")
        try await fixture.seed(profile: profile, entries: entries)
        let now = dates[3].addingTimeInterval(3_600)
        let model = fixture.model(profile: profile, currentDate: { now })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "GMT"))
        let snapshot = AppReportingSnapshot(instant: now, calendar: calendar)
        let entry = try XCTUnwrap(entries.last)

        func shot<V: View>(_ view: V, _ name: String, dark: Bool = false, height: CGFloat = 844) async {
            await capture(NavigationStack { view }.environment(model).environment(MoneyUpOverviewNavigation())
                .environment(\.appReportingSnapshot, snapshot).preferredColorScheme(dark ? .dark : .light),
                name: name, height: height)
        }
        await shot(AppSettingsView(), "audit-settings", height: 1400)
        await shot(DataSafetyView(), "audit-data-safety", dark: true, height: 1400)
        await shot(DisplaySettingsView(), "audit-display-settings")
        await shot(PrivacyAndBetaView(), "audit-privacy", height: 1200)
        await shot(TransactionEditView(entry: entry), "audit-transaction-edit", height: 1100)
        await shot(AccountManagementSheet(account: fixture.account), "audit-account-manage")
        await shot(AddAccountSheet(), "audit-account-add", dark: true)
        await shot(CategoryManagementSheet(categoryID: fixture.category.id), "audit-categories")
        await shot(EntryCatalogView(scope: .accounts), "audit-entry-catalog", dark: true)
        await shot(ImportTransactionsView(), "audit-import")
        await shot(InsightsView(), "audit-reports", dark: true, height: 1200)
        await shot(ExchangeRateEditorSheet(), "audit-rate-editor")
        await shot(AllowanceEditorSheet(plan: nil), "audit-allowance-editor", height: 1100)
        await capture(OnboardingView().environment(model).preferredColorScheme(.light), name: "audit-onboarding")
        await capture(WhatsNewSheet().environment(model).preferredColorScheme(.dark), name: "audit-whats-new")
        await fixture.store.close()
    }

    @MainActor
    private func capture<Content: View>(_ content: Content, name: String, width: CGFloat = 390, height: CGFloat = 844) async {
        let controller = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: "en")))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(900))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.opaque = true; format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
