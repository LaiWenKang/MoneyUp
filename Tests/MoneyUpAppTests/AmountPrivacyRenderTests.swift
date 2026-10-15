import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import Vision
import XCTest

/// Hiding amounts must hide every figure already on screen, at once. The eye
/// button and a Focus filter both only change the stored preference, so a
/// view that does not observe it can keep showing exact amounts after the
/// person hid them. Renders are read back from their pixels: a hosted SwiftUI
/// view builds no accessibility tree in a unit test. Fictional data only.
final class AmountPrivacyRenderTests: XCTestCase {
    @MainActor
    func testHidingAmountsHidesEveryFigureAlreadyOnEachPrimaryTab() async throws {
        let (fixture, model, snapshot) = try await makeFixture()
        defer { fixture.removeFiles() }
        let defaults = UserDefaults.standard
        let previousPrivacy = defaults.object(forKey: MoneyAmountPrivacy.storageKey)
        let languageDefaults = AppLanguagePreference.defaults
        let previousLanguage = languageDefaults?.object(forKey: AppLanguagePreference.storageKey)
        languageDefaults?.set(AppLanguagePreference.english.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previousPrivacy { defaults.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { defaults.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
            if let previousLanguage { languageDefaults?.set(previousLanguage, forKey: AppLanguagePreference.storageKey) }
            else { languageDefaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        var leaks: [String] = []
        for (tab, name) in [(MoneyUpSection.today, "today"), (.history, "history"), (.plan, "plan"), (.assets, "assets")] {
            defaults.set(false, forKey: MoneyAmountPrivacy.storageKey)
            let host = UIHostingController(rootView: MainTabView(initialReportingSnapshot: snapshot, initialSection: tab)
                .environment(model).environment(MoneyUpOverviewNavigation())
                .environment(\.locale, Locale(identifier: "en")).tint(.accentColor))
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            let shown = Self.amounts(in: await Self.settledImage(of: window, host: host))
            XCTAssertFalse(shown.isEmpty, "\(name): the fixture shows no amounts to hide")
            // The same write the eye button and a Focus filter make, to the
            // same live view.
            defaults.set(true, forKey: MoneyAmountPrivacy.storageKey)
            let hidden = await Self.settledImage(of: window, host: host)
            let attachment = XCTAttachment(image: hidden)
            attachment.name = "privacy-hidden-after-toggle-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let stillShown = shown.intersection(Self.amounts(in: hidden))
            if !stillShown.isEmpty { leaks.append("\(name): \(stillShown.sorted().joined(separator: ", "))") }
            window.isHidden = true
            window.rootViewController = nil
        }
        XCTAssertEqual(leaks, [], "Amounts still visible after hiding:\n" + leaks.joined(separator: "\n"))
        await fixture.store.close()
    }

    /// Figures written with a decimal part, such as 551.50 or 9,951.50. Axis
    /// labels and dates have none, so they are not mistaken for amounts.
    private static func amounts(in image: UIImage) -> Set<String> {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return Set(lines.flatMap { line in
            line.matches(of: /[0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2}/).map { String(line[$0.range]) }
        })
    }

    @MainActor
    private static func settledImage(of window: UIWindow, host: UIViewController) async -> UIImage {
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(900))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The book the primary-tab render evidence uses: a pinned Food budget
    /// with spending, income, a savings goal and a daily allowance.
    @MainActor
    private func makeFixture() async throws -> (AppModelFixture, AppModel, AppReportingSnapshot) {
        let fixture = try AppModelFixture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let income = LedgerAccount(name: "Salary", kind: .income)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, income]
        let entries = try [
            TransactionFactory.income(amount: Money(10_000, currency: fixture.sgd), depositedInto: fixture.wallet.id,
                category: income.id, occurredAt: now.addingTimeInterval(-86_400 * 3), payee: "Salary"),
            fixture.expense(amount: try XCTUnwrap(Decimal(string: "48.50")), occurredAt: now, payee: "Fresh groceries")
        ]
        let nodes = [BudgetNode(id: fixture.food.id, name: "Food", limit: try Money(600, currency: fixture.sgd), purpose: .flexible)]
        let goal = try SavingsGoal(name: "Home reserve", kind: .savingsGoal, target: Money(6_000, currency: fixture.sgd),
            targetDate: try XCTUnwrap(calendar.date(byAdding: .year, value: 1, to: now)),
            createdAt: now.addingTimeInterval(-86_400 * 90),
            movements: [SavingsGoalMovement(kind: .contribution, money: Money(2_000, currency: fixture.sgd),
                occurredAt: now.addingTimeInterval(-1), originTimeZoneIdentifier: calendar.timeZone.identifier)],
            reportingTimeZoneIdentifier: calendar.timeZone.identifier)
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: calendar.timeZone.identifier,
            pinnedBudgetNodeIDs: [fixture.food.id])
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes, savingsGoals: [goal])
        let model = fixture.model(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes,
            savingsGoals: [goal], currentDate: { now })
        return (fixture, model, AppReportingSnapshot(instant: now, calendar: calendar))
    }
}
