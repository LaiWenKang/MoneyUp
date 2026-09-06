import Foundation
@testable import MoneyUp
import MoneyUpCore
import UIKit
import SwiftUI
import XCTest

final class AppwideExperienceTests: XCTestCase {
    @MainActor
    func testOverviewWaitsForAnUnlockedActiveSceneAndConsumesOnce() {
        let navigation = MoneyUpOverviewNavigation()
        navigation.request(.today)
        XCTAssertNil(navigation.consume(isReady: false, isActive: false, isCovered: true))
        XCTAssertNil(navigation.consume(isReady: false, isActive: true, isCovered: false))
        XCTAssertNil(navigation.consume(isReady: true, isActive: false, isCovered: false))
        XCTAssertNil(navigation.consume(isReady: true, isActive: true, isCovered: true))
        XCTAssertEqual(navigation.pending, .today)
        XCTAssertEqual(navigation.consume(isReady: true, isActive: true, isCovered: false), .today)
        XCTAssertNil(navigation.consume(isReady: true, isActive: true, isCovered: false))
        navigation.request(.budget)
        XCTAssertEqual(navigation.consume(isReady: true, isActive: true, isCovered: false), .budget)
    }

    func testOverviewURLsAreExactAndNeverCarryFinancialInputs() throws {
        for route in MoneyUpOverviewRoute.allCases {
            let url = try XCTUnwrap(route.url)
            XCTAssertEqual(MoneyUpOverviewRoute(exactDeepLink: url), route)
            for suffix in ["?amount=20", "#secret", "/", "?", "%20"] {
                XCTAssertNil(MoneyUpOverviewRoute(exactDeepLink: try XCTUnwrap(URL(string: url.absoluteString + suffix))))
            }
        }
        for value in ["moneyup://overview/TODAY", "moneyup://overview/%74oday", "moneyup://user@overview/today", "https://overview/today"] {
            XCTAssertNil(MoneyUpOverviewRoute(exactDeepLink: try XCTUnwrap(URL(string: value))))
        }
    }

    @MainActor
    func testColdStartIsDeferredWhileInactiveAndCannotOverlapOrRepeatAfterUnlock() {
        let state = MoneyUpSceneLaunchState()
        XCTAssertFalse(state.claim(isLaunching: true))
        state.isActive = true
        XCTAssertTrue(state.claim(isLaunching: true))
        XCTAssertFalse(state.claim(isLaunching: true))
        state.isActive = false
        state.finish(wasDeferred: true)
        XCTAssertFalse(state.claim(isLaunching: true))
        state.isActive = true
        XCTAssertTrue(state.claim(isLaunching: true))
        state.finish(wasDeferred: false)
        XCTAssertFalse(state.claim(isLaunching: true))
        XCTAssertFalse(state.claim(isLaunching: false))
    }

    @MainActor
    func testInactiveInitialRoutingWindowDoesNotBeginProtectedStartup() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        model.state = .launching
        await model.startAfterInitialRoutingWindow(allowProtectedStart: { false })
        XCTAssertEqual(model.state, .launching)
        XCTAssertFalse(model.isWorking)
        await fixture.store.close()
    }

    func testEqualContributionPreviewUsesExactCeilingAndConservesMoney() throws {
        let result = try preview(balance: 30, target: 125, contribution: 20)
        XCTAssertEqual(result.periods, 5)
        XCTAssertEqual(result.added.amount, 100)
        XCTAssertEqual(result.projectedBalance.amount, 130)
        XCTAssertEqual(try preview(balance: 0, target: 1, contribution: Decimal(string: "0.33")!).periods, 4)
        XCTAssertEqual(try preview(balance: 150, target: 100, contribution: 20).periods, 0)
    }

    func testContributionPreviewRejectsInvalidInputsAndUnboundedHorizons() throws {
        XCTAssertThrowsError(try preview(balance: 0, target: 100, contribution: 0))
        XCTAssertThrowsError(try preview(balance: 0, target: 100, contribution: -1))
        XCTAssertThrowsError(try preview(balance: 0, target: 1_201, contribution: 1))
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        XCTAssertThrowsError(try GoalContributionProjection.make(
            balance: .zero(currency: sgd), target: Money(10, currency: sgd), contribution: Money(1, currency: usd),
            cadence: .monthly, asOf: Date(), calendar: Calendar(identifier: .gregorian)
        ))
        XCTAssertEqual(try preview(balance: 0, target: Decimal(string: "2e127")!, contribution: Decimal(string: "1e127")!).periods, 2)
    }

    func testContributionDatesUseCalendarMonthsAndKeepCivilTimeAcrossDST() throws {
        let january = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-31T12:00:00Z"))
        let monthly = try preview(balance: 0, target: 2, contribution: 1, asOf: january)
        XCTAssertEqual(monthly.completionDate, ISO8601DateFormatter().date(from: "2026-03-31T12:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-01T20:00:00Z"))
        let weekly = try preview(balance: 0, target: 2, contribution: 1, cadence: .weekly, asOf: start, calendar: calendar)
        XCTAssertEqual(weekly.completionDate, ISO8601DateFormatter().date(from: "2026-03-15T19:00:00Z"))
    }

    func testNetWorthChartDoesNotConvertOrInventMissingCurrencies() throws {
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        let snapshots = try [
            NetWorthSnapshot(capturedAt: Date(timeIntervalSince1970: 1), amounts: [Money(-20, currency: sgd)]),
            NetWorthSnapshot(capturedAt: Date(timeIntervalSince1970: 2), amounts: [Money(500, currency: usd)]),
            NetWorthSnapshot(capturedAt: Date(timeIntervalSince1970: 3), amounts: [Money(80, currency: sgd)])
        ]
        XCTAssertEqual(NetWorthHistoryPresentation.points(Array(snapshots.reversed()), currency: sgd).map(\.money.amount), [-20, 80])
        XCTAssertEqual(NetWorthHistoryPresentation.points(snapshots, currency: sgd, limit: 1).map(\.money.amount), [80])
        XCTAssertEqual(NetWorthHistoryPresentation.points(snapshots, currency: usd).map(\.money.amount), [500])
        XCTAssertTrue(NetWorthHistoryPresentation.points(snapshots, currency: sgd, limit: 0).isEmpty)
    }

    func testFilterBadgeCountsHiddenPredicatesWithoutDoubleCountingTheVisibleScope() {
        var filters = HistoryFilterDraft()
        filters.includesStartDate = true
        filters.includesEndDate = true
        XCTAssertEqual(filters.advancedFilterCount(quickRange: .today), 0)
        XCTAssertEqual(filters.advancedFilterCount(quickRange: .all), 1)
        filters.kind = .expense
        filters.minimumAmountText = "10"
        XCTAssertEqual(filters.advancedFilterCount(quickRange: .today), 2)
        XCTAssertEqual(filters.advancedFilterCount(quickRange: nil), 3)
    }

    func testEntryDirectionShowsExpenseIncomeRefundAndTransferCorrectly() {
        for kind in QuickLogKind.allCases {
            let route = MoneyUpEntryRoute.make(kind: kind, account: "Wallet", destination: "Bank", category: "Food")
            switch kind {
            case .expense: XCTAssertEqual([route.source.title, route.destination.title], ["Wallet", "Food"])
            case .income, .refund: XCTAssertEqual([route.source.title, route.destination.title], ["Food", "Wallet"])
            case .transfer: XCTAssertEqual([route.source.title, route.destination.title], ["Wallet", "Bank"])
            }
        }
    }

    @MainActor
    func testKeyboardDismissalWorksForAnOrdinaryTextField() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let field = UITextField(frame: CGRect(x: 20, y: 120, width: 240, height: 44))
        window.rootViewController = controller
        controller.view.addSubview(field)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        XCTAssertTrue(field.becomeFirstResponder())
        MoneyUpKeyboard.dismiss()
        XCTAssertFalse(field.isFirstResponder)
    }

    @MainActor
    func testEditedLogAmountSurvivesEveryTabAndRemainsAnEncryptedDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date()
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let draft = QuickLogDraft(kind: .expense, amountText: "18.60", destinationAmountText: "",
            accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: fixture.food.id,
            occurredAt: now, dateWasEdited: true, payee: "Lunch", note: "Keep this note", smartText: "")
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food]
        try await fixture.seed(profile: profile, accounts: accounts, quickLogDraft: draft)
        let model = fixture.model(profile: profile, accounts: accounts, quickLogDraft: draft, currentDate: { now })
        let selection = MoneyUpTabNavigation(section: .log)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let privacy = MoneyAmountPrivacy.hidesAmounts
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: MainTabView(
            initialReportingSnapshot: AppReportingSnapshot(instant: now, calendar: model.reportingCalendar), navigation: selection
        ).environment(model).environment(MoneyUpOverviewNavigation()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            UserDefaults.standard.set(privacy, forKey: MoneyAmountPrivacy.storageKey)
        }
        for _ in 0..<100 {
            if textFields(in: host.view).contains(where: { $0.text == "18.60" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let amount = try XCTUnwrap(textFields(in: host.view).first { $0.text == "18.60" })
        amount.text = "42.90"
        amount.sendActions(for: .editingChanged)
        for tab in [MoneyUpSection.today, .history, .plan, .assets, .log] {
            selection.section = tab
            try await Task.sleep(for: .milliseconds(200))
        }
        await model.quickLogDraftWriteTask?.value
        XCTAssertEqual(model.quickLogDraft?.amountText, "42.90")
        XCTAssertEqual(model.quickLogDraft?.note, "Keep this note")
        let persisted = try await fixture.store.fetch(QuickLogDraft.self, id: QuickLogDraft.primaryRecordID, from: .quickLogDrafts)
        XCTAssertEqual(persisted?.amountText, "42.90")
        let count = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(count, 0, "Changing tabs must never post a transaction")
        await fixture.store.close()
    }

    @MainActor
    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor
    func testNavigationAndBackupSymbolsExistOnTheSupportedOS() {
        for symbol in ["externaldrive.badge.checkmark", "wallet.bifold", "flag.checkered", "camera.aperture", "circle.dotted"] {
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
        }
    }

    private func preview(
        balance: Decimal, target: Decimal, contribution: Decimal,
        cadence: GoalContributionCadence = .monthly,
        asOf: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        calendar: Calendar? = nil
    ) throws -> GoalContributionProjection {
        let currency = try CurrencyCode("SGD")
        var resolved = calendar ?? Calendar(identifier: .gregorian)
        if calendar == nil { resolved.timeZone = .gmt }
        return try GoalContributionProjection.make(
            balance: Money(balance, currency: currency), target: Money(target, currency: currency),
            contribution: Money(contribution, currency: currency), cadence: cadence, asOf: asOf, calendar: resolved
        )
    }
}
