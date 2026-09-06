import Foundation
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

final class SmartOverviewRenderTests: XCTestCase {
    @MainActor
    func testNativeHomeCardsAcrossFocusAppearanceLanguageAndLargeText() async throws {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = BudgetWidgetSnapshot.available(percentUsed: 62, validUntil: expiry)
        let insights = MoneyUpWidgetInsights(reviewCount: 2, allowancePercentRemaining: 78,
            activeCommitmentCount: 3, daysUntilNextCommitment: 0, validUntil: expiry)
        for focus in [SmartOverviewFocus.automatic, .budget, .review, .allowance] {
            for isMedium in [false, true] {
                let state = SmartOverviewWidgetPresentation.make(budget: snapshot, insights: insights,
                    family: isMedium ? .systemMedium : .systemSmall)
                await capture(SmartOverviewHomeCard(presentation: state, focus: focus, isMedium: isMedium),
                    name: "widget-\(focus.rawValue)-\(isMedium ? "medium" : "small")", width: isMedium ? 338 : 158,
                    scheme: isMedium ? .dark : .light)
            }
        }
        let overspent = SmartOverviewWidgetPresentation.make(budget: .available(percentUsed: 999, validUntil: expiry),
            insights: nil, family: .systemSmall)
        await capture(SmartOverviewHomeCard(presentation: overspent, focus: .automatic, isMedium: false),
            name: "widget-over-budget-small", width: 158, scheme: .light)
        let large = SmartOverviewWidgetPresentation.make(budget: snapshot, insights: insights,
            family: .systemSmall, homeDensity: .accessibility)
        await capture(SmartOverviewHomeCard(presentation: large, focus: .automatic, isMedium: false)
            .environment(\.dynamicTypeSize, .accessibility5), name: "widget-large-chinese", width: 170, scheme: .light, language: .simplifiedChinese)
    }

    @MainActor
    private func capture<Content: View>(_ content: Content, name: String, width: CGFloat,
        scheme: ColorScheme, language: AppLanguagePreference = .english) async {
        let defaults = AppLanguagePreference.defaults
        let previous = defaults?.object(forKey: AppLanguagePreference.storageKey)
        defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppLanguagePreference.storageKey) }
            else { defaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        let view = content.padding(16).background(Color.moneyUpSurface).environment(\.locale, language.locale)
            .preferredColorScheme(scheme)
        let controller = UIHostingController(rootView: view)
        controller.safeAreaRegions = []
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 170)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, width)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
