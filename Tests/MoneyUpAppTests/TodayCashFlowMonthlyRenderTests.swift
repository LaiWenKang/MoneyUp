import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import XCTest

/// The chart alternative must retain the six individual months, rather than
/// substituting the unrelated period totals. Fictional data only.
final class TodayCashFlowMonthlyRenderTests: XCTestCase {
    @MainActor
    func testAccessibilitySizesRetainMonthlyValuesAndLiveMasking() async throws {
        for width in [320, 390] {
            try await verifyMonthlyValues(width: width)
        }
    }

    @MainActor
    func testMonthlyDetailLayoutDecisionForTextSizeAndVoiceOver() {
        // Tests the shared decision only. This does not enable VoiceOver or
        // demonstrate system activation, accessibility focus, or speech.
        for size in DynamicTypeSize.allCases {
            XCTAssertEqual(
                TodayCashFlowStory.usesMonthlyFlowDetails(dynamicTypeSize: size, voiceOverEnabled: false),
                size.isAccessibilitySize
            )
            XCTAssertTrue(TodayCashFlowStory.usesMonthlyFlowDetails(dynamicTypeSize: size, voiceOverEnabled: true))
        }
    }

    @MainActor
    private func verifyMonthlyValues(width: Int) async throws {
        let defaults = UserDefaults.standard
        let previousPrivacy = defaults.object(forKey: MoneyAmountPrivacy.storageKey)
        let languageDefaults = AppLanguagePreference.defaults
        let previousLanguage = languageDefaults?.object(forKey: AppLanguagePreference.storageKey)
        defaults.set(false, forKey: MoneyAmountPrivacy.storageKey)
        languageDefaults?.set(AppLanguagePreference.english.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previousPrivacy { defaults.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { defaults.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
            if let previousLanguage { languageDefaults?.set(previousLanguage, forKey: AppLanguagePreference.storageKey) }
            else { languageDefaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 10, day: 1)))
        let currency = try CurrencyCode("SGD")
        let zero = try Money(0, currency: currency)
        let months = try (0..<7).map { index in
            MonthlyFlow(
                month: try XCTUnwrap(calendar.date(byAdding: .month, value: index, to: start)),
                income: try Money(Decimal(10_101 + index * 100), currency: currency),
                expense: try Money(Decimal(20_202 + index * 100), currency: currency),
                net: zero
            )
        }
        // Check the actual shared formatter's exact ISO code for every
        // displayed amount. This is formatter evidence, not an OCR claim:
        // Vision sometimes reads SGD as SCD, so it cannot prove the code.
        for flow in months.suffix(6) {
            for money in [flow.income, flow.expense] {
                let formatted = formattedMoneyWithCurrencyCode(money)
                XCTAssertEqual(String(formatted.filter { $0.isLetter }), "SGD",
                    "Each monthly amount must retain its own exact currency: \(formatted)")
            }
        }
        let interval = DateInterval(start: start, duration: 86_400)
        let report = PeriodReport(interval: interval, trendInterval: interval,
            baseCurrency: currency,
            baseFlow: CurrencyFlow(currency: currency, income: zero, expense: zero, net: zero),
            foreignFlows: [], categorySpending: [], monthlyFlows: months)
        let host = UIHostingController(rootView: TodayCashFlowStory(report: report, calendar: calendar)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .accessibility5))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 3_600)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        let image = await LargeTextAmountRenderTests.settledLayerImage(of: host, scale: 2)
        let attachment = XCTAttachment(image: image)
        attachment.name = "cash-flow-monthly-\(width)-ax5"
        attachment.lifetime = .keepAlways
        add(attachment)
        let lines = LargeTextAmountRenderTests.recognizedLines(in: image)
        let shown = lines.joined(separator: " ")
        for index in 1..<7 {
            XCTAssertTrue(shown.contains("10,\(101 + index * 100).00"), "Missing monthly income: \(lines)")
            XCTAssertTrue(shown.contains("20,\(202 + index * 100).00"), "Missing monthly spending: \(lines)")
        }
        XCTAssertFalse(shown.contains("10,101.00"), "The seventh-oldest month is not in the chart")
        for month in ["November", "December", "January", "February", "March", "April"] {
            XCTAssertTrue(shown.contains(month), "Missing month label: \(lines)")
        }
        XCTAssertTrue(shown.contains("2025") && shown.contains("2026"))
        XCTAssertEqual(LargeTextAmountRenderTests.brokenAmounts(in: lines), [])

        // Change the real privacy preference on this same mounted view.
        defaults.set(true, forKey: MoneyAmountPrivacy.storageKey)
        let hiddenImage = await LargeTextAmountRenderTests.settledLayerImage(of: host, scale: 2)
        let hiddenAttachment = XCTAttachment(image: hiddenImage)
        hiddenAttachment.name = "cash-flow-monthly-\(width)-ax5-hidden"
        hiddenAttachment.lifetime = .keepAlways
        add(hiddenAttachment)
        let hidden = LargeTextAmountRenderTests.recognizedLines(in: hiddenImage).joined(separator: " ")
        XCTAssertTrue(hidden.contains("November"), "Do not accept a blank render as privacy evidence")
        for index in 1..<7 {
            XCTAssertFalse(hidden.contains("10,\(101 + index * 100).00"), "\(width) pt hidden render: \(hidden)")
            XCTAssertFalse(hidden.contains("20,\(202 + index * 100).00"), "\(width) pt hidden render: \(hidden)")
        }
    }
}
