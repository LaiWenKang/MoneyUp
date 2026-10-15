import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import Vision
import XCTest

/// At the largest accessibility text size, every amount Today shows must stay
/// whole: never cut to "…", never broken across lines away from its currency.
/// Read back from the pixels, at the narrowest and an ordinary iPhone width,
/// with amounts shown and figures long enough to need the room. Fictional
/// data only.
final class LargeTextAmountRenderTests: XCTestCase {
    @MainActor
    func testTodayKeepsEveryAmountWholeAtTheLargestTextSize() async throws {
        let (fixture, model, snapshot) = try await makeFixture()
        defer { fixture.removeFiles() }
        let defaults = UserDefaults.standard
        let previousPrivacy = defaults.object(forKey: MoneyAmountPrivacy.storageKey)
        defaults.set(false, forKey: MoneyAmountPrivacy.storageKey)
        let languageDefaults = AppLanguagePreference.defaults
        let previousLanguage = languageDefaults?.object(forKey: AppLanguagePreference.storageKey)
        languageDefaults?.set(AppLanguagePreference.english.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previousPrivacy { defaults.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { defaults.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
            if let previousLanguage { languageDefaults?.set(previousLanguage, forKey: AppLanguagePreference.storageKey) }
            else { languageDefaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        var problems: [String] = []
        for width in [320, 390] {
            let host = UIHostingController(rootView: MainTabView(initialReportingSnapshot: snapshot, initialSection: .today)
                .environment(model).environment(MoneyUpOverviewNavigation())
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.dynamicTypeSize, .accessibility5)
                .tint(.accentColor))
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
            // Tall enough for every Today card at this size to be laid out.
            // A window this far past the screen is not composited, so
            // drawHierarchy returns black: the layer tree is drawn instead.
            window.frame = CGRect(x: 0, y: 0, width: width, height: 3_600)
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            let image = await Self.settledLayerImage(of: host, scale: 2)
            let attachment = XCTAttachment(image: image)
            attachment.name = "large-text-today-ax5-\(width)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let lines = Self.recognizedLines(in: image)
            guard lines.contains(where: { $0.contains("Today") }) else {
                problems.append("\(width) pt: the render is blank, so nothing could be read")
                window.isHidden = true
                window.rootViewController = nil
                continue
            }
            problems += Self.brokenAmounts(in: lines).map { "\(width) pt: \($0)" }
            if !lines.contains(where: { $0.contains("122,222.22") }) {
                problems.append("\(width) pt: the cash position 122,222.22 is not shown whole")
            }
            window.isHidden = true
            window.rootViewController = nil
        }
        XCTAssertEqual(problems, [], "Amounts not whole at AX5:\n" + problems.joined(separator: "\n"))
        await fixture.store.close()
    }

    func testBrokenAmountDetectorSeesCutAndSplitFigures() {
        XCTAssertEqual(Self.brokenAmounts(in: ["SGD 10,765.44", "Left this month", "Day SGD 358.85"]), [])
        XCTAssertEqual(Self.brokenAmounts(in: ["SGD 122,2…"]), ["SGD 122,2…"])
        XCTAssertEqual(Self.brokenAmounts(in: ["Food...", "SGD 1,234.56"]), ["Food..."])
        XCTAssertEqual(Self.brokenAmounts(in: ["SGD 10,7", "65.44"]), ["65.44"])
    }

    /// Lines cut with an ellipsis, and figures separated from their currency
    /// code (a number broken across lines leaves its tail without "SGD").
    static func brokenAmounts(in lines: [String]) -> [String] {
        lines.filter { line in
            if line.contains("…") || line.contains("...") { return true }
            let hasFigure = line.contains(/[0-9]+\.[0-9]{2}/)
            let hasCode = line.replacingOccurrences(of: " ", with: "").uppercased().contains("SGD")
            return hasFigure && !hasCode
        }
    }

    static func recognizedLines(in image: UIImage) -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// The hosting view drawn from its layer tree, for content taller than
    /// the screen; materials and blurs are not drawn, text and shapes are.
    @MainActor
    static func settledLayerImage(of host: UIViewController, scale: CGFloat) async -> UIImage {
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(900))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        return UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(host.view.bounds)
            host.view.layer.render(in: context.cgContext)
        }
    }

    @MainActor
    static func settledImage(of window: UIWindow, host: UIViewController, scale: CGFloat = 3) async -> UIImage {
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(900))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// A pinned Food budget of 12,000 with 1,234.56 spent from a wallet that
    /// received 123,456.78: cash 122,222.22, Food left 10,765.44.
    @MainActor
    private func makeFixture() async throws -> (AppModelFixture, AppModel, AppReportingSnapshot) {
        let fixture = try AppModelFixture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let income = LedgerAccount(name: "Salary", kind: .income)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, income]
        let entries = try [
            TransactionFactory.income(
                amount: Money(try XCTUnwrap(Decimal(string: "123456.78")), currency: fixture.sgd),
                depositedInto: fixture.wallet.id, category: income.id,
                occurredAt: now.addingTimeInterval(-86_400 * 3), payee: "Salary"
            ),
            fixture.expense(amount: try XCTUnwrap(Decimal(string: "1234.56")), occurredAt: now, payee: "Groceries")
        ]
        let nodes = [BudgetNode(id: fixture.food.id, name: "Food", limit: try Money(12_000, currency: fixture.sgd), purpose: .flexible)]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: calendar.timeZone.identifier,
            pinnedBudgetNodeIDs: [fixture.food.id])
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes)
        let model = fixture.model(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes,
            currentDate: { now })
        return (fixture, model, AppReportingSnapshot(instant: now, calendar: calendar))
    }
}
