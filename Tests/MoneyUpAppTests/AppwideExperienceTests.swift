import Foundation
@testable import MoneyUp
import MoneyUpCore
import UIKit
import SwiftUI
import XCTest

final class AppwideExperienceTests: XCTestCase {
    @MainActor
    func testSpreadsheetTypeIsDeclaredInTheBuiltBundle() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        let spreadsheet = try XCTUnwrap(declarations.first { ($0["UTTypeIdentifier"] as? String) == "org.openxmlformats.spreadsheetml.sheet" })
        let tags = try XCTUnwrap(spreadsheet["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["xlsx"])
        XCTAssertEqual(tags["public.mime-type"] as? String, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    }

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

    func testCategoryGlyphsPreferPresetThenNameThenAncestor() {
        let dining = LedgerAccount(name: "Anything", kind: .expense, presetID: "expense.dining")
        let transport = LedgerAccount(name: "Transport", kind: .expense)
        let child = LedgerAccount(name: "Weekday rides", kind: .expense, parentID: transport.id)
        let unknown = LedgerAccount(name: "Zzz", kind: .expense)
        let salary = LedgerAccount(name: "工资", kind: .income)
        let otherIncome = LedgerAccount(name: "Zzz", kind: .income)
        let accounts = Dictionary(uniqueKeysWithValues: [dining, transport, child, unknown, salary, otherIncome].map { ($0.id, $0) })
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(for: dining.id, accountsByID: accounts), "fork.knife")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(for: transport.id, accountsByID: accounts), "bus.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(for: child.id, accountsByID: accounts), "bus.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(for: unknown.id, accountsByID: accounts), MoneyUpCategorySymbol.fallbackExpense)
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(for: salary.id, accountsByID: accounts), "briefcase.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(for: otherIncome.id, accountsByID: accounts), MoneyUpCategorySymbol.fallbackIncome)
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(for: UUID(), accountsByID: accounts), MoneyUpCategorySymbol.fallbackExpense)
    }

    func testCategoryNameKeywordsAvoidShortWordFalseMatches() {
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "Food & coffee"), "fork.knife")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "Coffee"), "cup.and.saucer.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "Groceries"), "basket.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "Everyday essentials"), "cart.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "水电网费"), "bolt.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "餐饮"), "fork.knife")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "Taxi"), "car.fill")
        XCTAssertEqual(MoneyUpCategorySymbol.symbol(forName: "Taxes"), "doc.text.fill")
        XCTAssertNil(MoneyUpCategorySymbol.symbol(forName: "Petty cash"))
        XCTAssertNil(MoneyUpCategorySymbol.symbol(forName: "Category nine"))
        let id = UUID()
        XCTAssertEqual(MoneyUpCategorySymbol.tint(for: id), MoneyUpCategorySymbol.tint(for: id))
    }

    func testPaceStatusMatchesTheSharedPaceReading() {
        XCTAssertEqual(MoneyUpPaceStatus(ratio: 0.40, elapsed: 0.50), .within)
        XCTAssertEqual(MoneyUpPaceStatus(ratio: 0.55, elapsed: 0.50), .within)
        XCTAssertEqual(MoneyUpPaceStatus(ratio: 0.56, elapsed: 0.50), .ahead)
        XCTAssertEqual(MoneyUpPaceStatus(ratio: 1.01, elapsed: 0.99), .over)
        XCTAssertEqual(MoneyUpPaceStatus(ratio: 2, elapsed: 0), .over)
    }

    @MainActor
    func testIncomingRowAmountsCarryAnExplicitSign() throws {
        let previous = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        let money = try Money(12, currency: CurrencyCode("SGD"))
        XCTAssertTrue(rowFormattedAmount(TransactionDisplayAmount(money: money, role: .income)).hasPrefix("+"))
        XCTAssertTrue(rowFormattedAmount(TransactionDisplayAmount(money: money.negated, role: .refund)).hasPrefix("+"))
        XCTAssertFalse(rowFormattedAmount(TransactionDisplayAmount(money: money, role: .expense)).hasPrefix("+"))
        UserDefaults.standard.set(true, forKey: MoneyAmountPrivacy.storageKey)
        XCTAssertEqual(rowFormattedAmount(TransactionDisplayAmount(money: money, role: .income)), MoneyAmountPrivacy.placeholder)
    }

    func testQuickCategoryChipsRankByUseAndNeverMoveTheSelection() throws {
        let usd = try CurrencyCode("USD")
        let wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: usd)
        let group = LedgerAccount(name: "Essentials", kind: .expense)
        let food = LedgerAccount(name: "Food", kind: .expense, parentID: group.id)
        let transport = LedgerAccount(name: "Transport", kind: .expense, parentID: group.id)
        let rent = LedgerAccount(name: "Rent", kind: .expense)
        let fun = LedgerAccount(name: "Fun", kind: .expense)
        let choices = [group, food, transport, rent, fun]
        let entries = try [transport, transport, rent].map {
            try TransactionFactory.expense(amount: Money(5, currency: usd), paidFrom: wallet.id, category: $0.id)
        }
        let ranked = QuickLogCategoryRanking.ranked(choices: choices, recentEntries: entries, selected: nil, limit: 3)
        XCTAssertEqual(ranked.map(\.name), ["Transport", "Rent", "Food"], "used first, unused group heading left out")
        let withSelection = QuickLogCategoryRanking.ranked(choices: choices, recentEntries: entries, selected: rent.id, limit: 3)
        XCTAssertEqual(withSelection.map(\.name), ["Transport", "Rent", "Food"], "a visible selection keeps its place")
        let outside = QuickLogCategoryRanking.ranked(choices: choices, recentEntries: entries, selected: fun.id, limit: 3)
        XCTAssertEqual(outside.map(\.name), ["Transport", "Rent", "Fun"], "an off-list selection takes the last slot")
    }

    func testStarterBudgetSplitAddsToOneHundredAndMarksBills() throws {
        let nodes = [
            BudgetNode(name: "Everyday essentials"), BudgetNode(name: "Housing"), BudgetNode(name: "Lifestyle"),
            BudgetNode(parentID: UUID(), name: "Food")
        ]
        let shares = StarterBudgetSplit.suggested(for: nodes)
        XCTAssertEqual(shares.map(\.name), ["Housing", "Everyday essentials", "Lifestyle"])
        XCTAssertEqual(shares.map(\.percent), [40, 35, 25])
        XCTAssertEqual(shares.first?.purpose, .commitment)
        XCTAssertEqual(Set(shares.dropFirst().map(\.purpose)), [.flexible])
        XCTAssertTrue(shares.allSatisfy { $0.percent % 5 == 0 })
        XCTAssertEqual(StarterBudgetSplit.amount(total: 3001, percent: 35), 1050)
        let limited = try BudgetNode(name: "Housing", limit: Money(10, currency: CurrencyCode("USD")))
        XCTAssertTrue(StarterBudgetSplit.suggested(for: [limited]).isEmpty, "existing limits are never proposed again")
    }

    func testCalendarDayMarksSeparateSpendingIncomeAndTransfers() throws {
        let usd = try CurrencyCode("USD")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-10T10:00:00Z"))
        let wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: usd)
        let savings = LedgerAccount(name: "Savings", kind: .asset, currency: usd)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let entries = try [
            TransactionFactory.expense(amount: Money(5, currency: usd), paidFrom: wallet.id, category: food.id, occurredAt: day),
            TransactionFactory.income(amount: Money(50, currency: usd), depositedInto: wallet.id, category: salary.id,
                occurredAt: day.addingTimeInterval(86_400)),
            TransactionFactory.transfer(amount: Money(5, currency: usd), from: wallet.id, to: savings.id,
                occurredAt: day.addingTimeInterval(2 * 86_400))
        ]
        let marks = CalendarDayMarks.byDay(entries: entries, calendar: calendar)
        XCTAssertEqual(marks[calendar.startOfDay(for: day)], CalendarDayMarks(spent: true))
        XCTAssertEqual(marks[calendar.startOfDay(for: day.addingTimeInterval(86_400))], CalendarDayMarks(received: true))
        XCTAssertNil(marks[calendar.startOfDay(for: day.addingTimeInterval(2 * 86_400))])
    }
}
