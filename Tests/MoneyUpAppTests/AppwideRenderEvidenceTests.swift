import Foundation
@testable import MoneyUp
import MoneyUpCore
import Observation
import SwiftUI
import UIKit
import XCTest

final class AppwideRenderEvidenceTests: XCTestCase {
    @MainActor
    func testPlanToolbarSurvivesRetainedTabAndAppearanceChanges() async throws {
        let (fixture, model, snapshot) = try await makeFixture()
        defer { fixture.removeFiles() }
        let navigation = MoneyUpTabNavigation(section: .plan)
        let appearance = ReviewAppearance()
        let controller = UIHostingController(rootView: RetainedPlanReview(model: model, snapshot: snapshot,
            navigation: navigation, appearance: appearance))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        for (index, scheme) in [ColorScheme.dark, .light, .dark, .light].enumerated() {
            navigation.section = .today
            appearance.scheme = scheme
            try? await Task.sleep(for: .milliseconds(200))
            navigation.section = .plan
            try? await Task.sleep(for: .milliseconds(500))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(navigation.section, .plan)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "plan-appearance-cycle-\(index)-\(scheme == .light ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        await fixture.store.close()
    }

    @MainActor
    func testRenderEveryPrimaryTabAndPlanningTool() async throws {
        let (fixture, model, snapshot) = try await makeFixture()
        defer { fixture.removeFiles() }
        let previousPrivacy = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previousPrivacy { UserDefaults.standard.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        let tabs: [(MoneyUpSection, String)] = [(.today, "today"), (.history, "history"), (.log, "log"), (.plan, "plan"), (.assets, "assets")]
        for (tab, name) in tabs {
            await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: tab).environment(model)
                .environment(MoneyUpOverviewNavigation()).preferredColorScheme(.dark), name: "full-" + name)
            await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: tab).environment(model)
                .environment(MoneyUpOverviewNavigation()).preferredColorScheme(.light), name: "full-light-" + name)
        }
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .plan, initialPlanSection: .calendar)
            .environment(model).environment(MoneyUpOverviewNavigation()).preferredColorScheme(.light), name: "full-calendar")
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .plan, initialPlanSection: .goals)
            .environment(model).environment(MoneyUpOverviewNavigation()).preferredColorScheme(.dark), name: "full-goals")
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .log).environment(model)
            .environment(MoneyUpOverviewNavigation()).environment(\.dynamicTypeSize, .accessibility2)
            .preferredColorScheme(.light), name: "log-large-text", height: 950)
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .assets).environment(model)
            .environment(MoneyUpOverviewNavigation()).preferredColorScheme(.light), name: "assets-small-chinese", width: 320, language: .simplifiedChinese)
        let goal = try XCTUnwrap(model.savingsGoals.first)
        let summary = try XCTUnwrap(model.savingsGoalSummary(goal, asOf: snapshot.instant).value)
        await capture(GoalDetailView(goalID: goal.id).environment(model).environment(\.appReportingSnapshot, snapshot)
            .preferredColorScheme(.dark), name: "goal-detail")
        await capture(GoalContributionSimulator(summary: summary, calendar: snapshot.calendar, initialContributionText: "250")
            .padding().background(Color.moneyUpBackground).preferredColorScheme(.light), name: "goal-contribution-preview", height: 600)
        await capture(AssetsSnapshotTrend().environment(model).padding().background(Color.moneyUpBackground)
            .preferredColorScheme(.dark), name: "assets-snapshot-chart", height: 480)
        await capture(ExchangeRateEditorSheet().environment(model).preferredColorScheme(.light), name: "exchange-rate-editor")
        await fixture.store.close()
    }

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
            fixture.expense(amount: Decimal(string: "48.50")!, occurredAt: now, payee: "Fresh groceries")
        ]
        let nodes = [BudgetNode(id: fixture.food.id, name: "Food", limit: try Money(600, currency: fixture.sgd), purpose: .flexible)]
        let goal = try SavingsGoal(name: "Home reserve", kind: .savingsGoal, target: Money(6_000, currency: fixture.sgd),
            targetDate: calendar.date(byAdding: .year, value: 1, to: now)!, createdAt: now.addingTimeInterval(-86_400 * 90),
            movements: [SavingsGoalMovement(kind: .contribution, money: Money(2_000, currency: fixture.sgd), occurredAt: now.addingTimeInterval(-1), originTimeZoneIdentifier: calendar.timeZone.identifier)],
            reportingTimeZoneIdentifier: calendar.timeZone.identifier)
        let allowance = try AllowancePlan(name: "Meal benefit", amount: Money(15, currency: fixture.sgd), cadence: .daily,
            startsAt: calendar.startOfDay(for: now), timeZoneIdentifier: calendar.timeZone.identifier, eligibleCategoryIDs: [fixture.food.id])
        let snapshots = try (1...6).map { index in
            try NetWorthSnapshot(capturedAt: calendar.date(byAdding: .month, value: index - 7, to: now)!,
                amounts: [Money(Decimal(6_000 + index * 500), currency: fixture.sgd), Money(Decimal(index * 100), currency: fixture.usd)])
        }
        let draft = QuickLogDraft(kind: .expense, amountText: "18.60", destinationAmountText: "", accountID: fixture.wallet.id,
            destinationAccountID: nil, categoryID: fixture.food.id, occurredAt: now, dateWasEdited: true,
            payee: "Lunch", note: "Draft retained while switching tabs", smartText: "")
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: calendar.timeZone.identifier, pinnedBudgetNodeIDs: [fixture.food.id])
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes, savingsGoals: [goal], allowancePlans: [allowance], quickLogDraft: draft)
        let model = fixture.model(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes, allowancePlans: [allowance],
            netWorthSnapshots: snapshots, savingsGoals: [goal], quickLogDraft: draft, currentDate: { now })
        return (fixture, model, AppReportingSnapshot(instant: now, calendar: calendar))
    }

    @MainActor
    private func capture<Content: View>(
        _ content: Content, name: String, width: CGFloat = 390, height: CGFloat = 844,
        language: AppLanguagePreference = .english
    ) async {
        let defaults = AppLanguagePreference.defaults
        let previous = defaults?.object(forKey: AppLanguagePreference.storageKey)
        defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppLanguagePreference.storageKey) }
            else { defaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        let controller = UIHostingController(rootView: content.environment(\.locale, language.locale))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(800))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor @Observable private final class ReviewAppearance {
    var scheme = ColorScheme.dark
}

private struct RetainedPlanReview: View {
    let model: AppModel
    let snapshot: AppReportingSnapshot
    let navigation: MoneyUpTabNavigation
    let appearance: ReviewAppearance

    var body: some View {
        MainTabView(initialReportingSnapshot: snapshot, navigation: navigation)
            .environment(model).environment(MoneyUpOverviewNavigation())
            .preferredColorScheme(appearance.scheme)
    }
}
