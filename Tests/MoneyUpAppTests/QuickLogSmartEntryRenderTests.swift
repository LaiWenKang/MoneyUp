import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import SwiftUI
import UIKit
import Vision
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
            ("en", 390, .large), ("zh-Hans", 320, .large), ("en", 390, .accessibility2),
            ("en", 390, .large), ("en", 390, .large)
        ]
        for (index, scenario) in scenarios.enumerated() {
            if index == 3 {
                let phrase = "lunch USD12 Wallet yesterday"
                let now = Date(timeIntervalSince1970: 1_788_933_600)
                let draft = QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "",
                    accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: fixture.food.id,
                    occurredAt: now, dateWasEdited: false, payee: "", note: "", smartText: phrase)
                model.updateQuickLogDraft(QuickLogUnderstandingFill.fill(
                    SmartEntryInterpreter.interpret(phrase, accounts: model.accounts, now: now),
                    current: draft, accounts: model.accounts, now: now))
            } else if index == 4, let draft = model.quickLogDraft {
                try await model.clearQuickLogDraft(replacing: draft)
            }
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


extension QuickLogSmartEntryRenderTests {
    @MainActor
    func testHistoryPreloadAndManualRateLayouts() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date()
        let entries = try [100.0, 200].map {
            try TransactionFactory.expense(amount: Money(7, currency: fixture.sgd),
                paidFrom: fixture.wallet.id, category: fixture.food.id,
                occurredAt: now.addingTimeInterval(-$0), payee: "Morning Coffee")
        }
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food], entries: entries)
        let model = fixture.model(entries: entries)
        let predictions = await model.historyPreloadSuggestions(for: CaptureSuggestionQuery(
            kind: .expense, currency: fixture.sgd, occurredAt: now), eligibleCategoryIDs: [fixture.food.id])
        let prediction = try XCTUnwrap(predictions.merchants.first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let priorWindow = scene.windows.first { $0.isKeyWindow }
        defer {
            window.isHidden = true
            window.rootViewController = nil
            priorWindow?.makeKey()
        }
        let defaults = try XCTUnwrap(AppLanguagePreference.defaults)
        let priorLanguage = defaults.string(forKey: AppLanguagePreference.storageKey)
        defer {
            if let priorLanguage { defaults.set(priorLanguage, forKey: AppLanguagePreference.storageKey) }
            else { defaults.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        for language in ["en", "zh-Hans"] {
            defaults.set(language, forKey: AppLanguagePreference.storageKey)
            for mode in [0, 1, 2] {
                let rate = mode == 1
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                let content: AnyView = mode == 2
                    ? AnyView(Form {
                        HistoryPreloadCard(suggestion: prediction, accountName: "Wallet", categoryName: "Food",
                            available: QuickLogHistoryPreloadFill.fields, canApplyAll: true,
                            apply: { _ in XCTFail("Rendering must not fill the draft") }, expanded: true)
                    })
                    : rate
                    ? AnyView(ManualTransferRateSheet(source: try Money(100, currency: fixture.sgd),
                        destination: fixture.usd, apply: { _ in XCTFail("Rendering must not apply a rate") }))
                    : AnyView(QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false,
                        isActive: false, launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in }))
                let host = UIHostingController(rootView: content.environment(model)
                    .environment(\.locale, Locale(identifier: language)))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                var image = UIImage()
                var merchantVisible = false
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(250))
                    host.view.layoutIfNeeded()
                    image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    if rate { break }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
                    merchantVisible = request.results?.contains {
                        $0.topCandidates(1).first?.string.contains("Morning Coffee") == true
                    } == true
                    if merchantVisible { break }
                }
                if !rate { XCTAssertTrue(merchantVisible, "The preload must be visible before scrolling") }
                let attachment = XCTAttachment(image: image)
                attachment.name = "context-preload-\(mode)-\(language)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(model.entries.count, 2)
                XCTAssertTrue(model.quickLogDraft?.payee.isEmpty ?? true)
            }
        }
        await fixture.store.close()
    }
}
