import Foundation
@testable import MoneyUp
import MoneyUpCore
import Observation
import SwiftUI
import UIKit
import XCTest

final class AppwideRenderEvidenceTests: XCTestCase {
    @MainActor
    func testCaptureAppStoreScreenshots() async throws {
        let previousPrivacy = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previousPrivacy { UserDefaults.standard.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        for language in [AppLanguagePreference.english, .simplifiedChinese] {
            let (fixture, model, snapshot) = try await AppStoreScreenshotFixture.make(chinese: language == .simplifiedChinese)
            defer { fixture.removeFiles() }
            let prefix = language == .english ? "store-en-" : "store-zh-"
            let chinese = language == .simplifiedChinese
            for (tab, name) in [(MoneyUpSection.today, "today"), (.log, "log"), (.plan, "plan"), (.history, "history"), (.assets, "assets")] {
                if tab == .history { model.quickLogDraft = nil }
                let dark = [MoneyUpSection.today, .assets, .log].contains(tab)
                let screen = await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: tab)
                    .environment(model).environment(MoneyUpOverviewNavigation()).preferredColorScheme(dark ? .dark : .light),
                    name: prefix + name, width: 428, height: 926, language: language)
                let copy = storeCopy(name, chinese: chinese)
                await capture(AppStoreFeatureArtwork(title: copy.0, subtitle: copy.1, chinese: chinese, dark: dark) {
                    Image(uiImage: screen).resizable().scaledToFit()
                }, name: prefix + "feature-" + name, width: 428, height: 926, language: language)
                if tab == .today {
                    await capture(AppStoreBrandArtwork(chinese: chinese, screen: screen),
                                  name: prefix + "feature-brand", width: 428, height: 926, language: language)
                }
            }
            for (section, name) in [(PlanSection.goals, "goals"), (.calendar, "calendar")] {
                let screen = await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .plan, initialPlanSection: section)
                    .environment(model).environment(MoneyUpOverviewNavigation()).preferredColorScheme(.light),
                    name: prefix + name, width: 428, height: 926, language: language)
                let copy = storeCopy(name, chinese: chinese)
                await capture(AppStoreFeatureArtwork(title: copy.0, subtitle: copy.1, chinese: chinese) {
                    Image(uiImage: screen).resizable().scaledToFit()
                }, name: prefix + "feature-" + name, width: 428, height: 926, language: language)
            }
            let mode = ProcessInfo.processInfo.environment["MONEYUP_CAPTURE_STORE_VIDEO"]
            let videoLanguage = ProcessInfo.processInfo.environment["MONEYUP_CAPTURE_VIDEO_LANGUAGE"]
            if let mode, ["1", "brand-only"].contains(mode), videoLanguage == nil || videoLanguage == language.rawValue {
                for brandOnly in mode == "brand-only" ? [true] : [false, true] {
                    let video = try await AppStorePreviewRecorder.record(model: model, snapshot: snapshot,
                        language: language, brandOnly: brandOnly)
                    let attachment = XCTAttachment(contentsOfFile: video)
                    attachment.name = prefix + (brandOnly ? "brand-video" : "preview-video")
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            await fixture.store.close()
        }
    }

    private func storeCopy(_ name: String, chinese: Bool) -> (String, String) {
        switch (name, chinese) {
        case ("today", false): ("Spending in view.\nMore room for you.", "Your everyday budgets, at a glance.")
        case ("today", true): ("开销有记录，\n心里就有数。", "关注日常预算，从容安排今天。")
        case ("plan", false): ("Plan with care.\nSee what’s spare.", "See what is spent and what is still yours.")
        case ("plan", true): ("预算先分配，\n花钱有准备。", "已花多少，还剩多少，一眼明白。")
        case ("history", false): ("See what went.\nKnow what you spent.", "Your spending story, clearly recorded.")
        case ("history", true): ("每笔有来去，\n回头有依据。", "收支记录清清楚楚，回顾更轻松。")
        case ("assets", false): ("Know what’s there.\nPlan with care.", "Accounts and currencies, side by side.")
        case ("assets", true): ("账户分得开，\n家底看明白。", "账户与币种分别呈现，数字更清楚。")
        case ("goals", false): ("A goal in sight.\nA future you write.", "Watch your savings goals take shape.")
        case ("goals", true): ("心愿有方向，\n存钱有盼望。", "储蓄目标有进度，每一步都看得见。")
        case ("log", false): ("Tap. Track.\nGet your day back.", "Record an expense and get on with your day.")
        case ("log", true): ("开销随手记，\n生活有底气。", "记录日常开销，不打断生活节奏。")
        case (_, false): ("See each day.\nPlan your way.", "Explore the rhythm of your cash flow.")
        case (_, true): ("收支按天看，\n心里有盘算。", "在日历中回顾每一天的资金流。")
        }
    }

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
    @discardableResult
    private func capture<Content: View>(
        _ content: Content, name: String, width: CGFloat = 390, height: CGFloat = 844,
        language: AppLanguagePreference = .english
    ) async -> UIImage {
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
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
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
