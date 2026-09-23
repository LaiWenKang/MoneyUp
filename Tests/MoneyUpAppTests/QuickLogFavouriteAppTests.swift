import Foundation
import MoneyUpCore
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

/// Favourites prefill Log and never post by themselves; the widget card is
/// data-free and keeps a stable, labelled layout per size.
final class QuickLogFavouriteAppTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    private func draft(
        kind: QuickLogKind = .expense,
        amountText: String = "",
        accountID: UUID? = nil,
        categoryID: UUID? = nil,
        payee: String = "",
        note: String = ""
    ) -> QuickLogDraft {
        QuickLogDraft(
            kind: kind, amountText: amountText, destinationAmountText: "",
            accountID: accountID, destinationAccountID: nil, categoryID: categoryID,
            occurredAt: Date(timeIntervalSince1970: 1_790_000_000), dateWasEdited: false,
            payee: payee, note: note, smartText: ""
        )
    }

    func testAmountOnlyFavouriteKeepsTypedAmountAndFillsTheRest() {
        let wallet = UUID(), food = UUID()
        let lunch = QuickLogFavourite(name: "Lunch", kind: .expense, accountID: wallet,
                                      categoryID: food, payee: "Hawker")
        let filled = QuickLogFavouriteFill.fill(
            lunch, current: draft(amountText: "8.5"),
            usableAccountIDs: [wallet], usableCategoryIDs: [food], locale: posix
        )
        XCTAssertEqual(filled.amountText, "8.5")
        XCTAssertEqual(filled.accountID, wallet)
        XCTAssertEqual(filled.categoryID, food)
        XCTAssertTrue(filled.accountWasEdited)
        XCTAssertTrue(filled.categoryWasEdited)
        XCTAssertEqual(filled.payee, "Hawker")
        XCTAssertFalse(filled.dateWasEdited, "A favourite is a new entry with a fresh time")
    }

    func testFixedAmountFavouriteFillsAmountAndSkipsStaleReferences() {
        let current = UUID(), stale = UUID()
        let coffee = QuickLogFavourite(name: "Coffee", kind: .expense, amount: Decimal(string: "3.2"),
                                       accountID: stale, categoryID: stale)
        let filled = QuickLogFavouriteFill.fill(
            coffee, current: draft(accountID: current, categoryID: current),
            usableAccountIDs: [current], usableCategoryIDs: [current], locale: posix
        )
        XCTAssertEqual(filled.amountText, "3.2")
        XCTAssertEqual(filled.accountID, current, "A missing account is never guessed")
        XCTAssertEqual(filled.categoryID, current)
        XCTAssertFalse(filled.accountWasEdited)
    }

    func testFavouriteSwitchesKindButNeverErasesTypedText() {
        let salary = QuickLogFavourite(name: "Salary", kind: .income)
        let filled = QuickLogFavouriteFill.fill(
            salary, current: draft(payee: "ACME", note: "Sept"),
            usableAccountIDs: [], usableCategoryIDs: [], locale: posix
        )
        XCTAssertEqual(filled.kind, .income)
        XCTAssertEqual(filled.payee, "ACME")
        XCTAssertEqual(filled.note, "Sept")
    }

    func testSavedEntryCandidateCoversOnlySingleExpenseOrIncome() throws {
        let wallet = UUID(), food = UUID()
        let candidate = try XCTUnwrap(QuickLogFavouriteFill.candidate(
            from: draft(amountText: "3.2", accountID: wallet, categoryID: food, payee: " Kopi "),
            categoryName: "Food", locale: posix
        ))
        XCTAssertEqual(candidate.name, "Kopi")
        XCTAssertEqual(candidate.amount, Decimal(string: "3.2"))
        XCTAssertEqual(candidate.accountID, wallet)
        XCTAssertEqual(QuickLogFavouriteFill.candidate(
            from: draft(amountText: "3", categoryID: food), categoryName: "Food", locale: posix
        )?.name, "Food")
        XCTAssertNil(QuickLogFavouriteFill.candidate(from: draft(kind: .transfer), categoryName: nil))
        XCTAssertNil(QuickLogFavouriteFill.candidate(from: draft(kind: .refund), categoryName: nil))
        var split = draft()
        split.splitLines = [QuickLogSplitDraftLine(), QuickLogSplitDraftLine()]
        XCTAssertNil(QuickLogFavouriteFill.candidate(from: split, categoryName: nil))
    }

    @MainActor
    func testModelSavesReordersDeletesAndPersistsWithoutPosting() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food])
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food])
        let coffee = QuickLogFavourite(name: "Coffee", kind: .expense, amount: 3,
                                       accountID: fixture.wallet.id, categoryID: fixture.food.id)
        let lunch = QuickLogFavourite(name: "Lunch", kind: .expense, categoryID: fixture.food.id)
        try await model.saveQuickLogFavourite(coffee)
        try await model.saveQuickLogFavourite(lunch)
        var renamed = coffee
        renamed.name = "Kopi"
        try await model.saveQuickLogFavourite(renamed)
        XCTAssertEqual(model.quickLogFavourites.map(\.name), ["Kopi", "Lunch"])

        try await model.moveQuickLogFavourites(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(model.quickLogFavourites.map(\.name), ["Lunch", "Kopi"])
        try await model.deleteQuickLogFavourite(id: lunch.id)
        XCTAssertEqual(model.quickLogFavourites, [renamed])
        XCTAssertTrue(model.entries.isEmpty, "Managing favourites never posts a transaction")
        XCTAssertTrue(model.quickLogFavouriteRepairs(renamed).isEmpty)

        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let saved = try await reopened.fetch(UserProfile.self, id: UserProfile.primaryRecordID, from: .profile)
        XCTAssertEqual(saved?.quickLogFavourites, [renamed])
        await reopened.close()
    }

    @MainActor
    func testRepairsFlagMissingAccountAndCategoryOfTheWrongKind() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(accounts: [fixture.wallet, fixture.food])
        let broken = QuickLogFavourite(name: "Old card", kind: .expense, accountID: UUID(), categoryID: UUID())
        XCTAssertEqual(model.quickLogFavouriteRepairs(broken), [.account, .category])
        let wrongKind = QuickLogFavourite(name: "Salary", kind: .income, accountID: fixture.wallet.id,
                                          categoryID: fixture.food.id)
        XCTAssertEqual(model.quickLogFavouriteRepairs(wrongKind), [.category])
        XCTAssertTrue(model.quickLogFavouriteRepairs(
            QuickLogFavourite(name: "Lunch", kind: .expense)
        ).isEmpty, "Unset references are choices for Log, not repairs")
    }

    func testWidgetShortcutsAreStableLabelledAndExcludeTheMainAction() {
        // Every surface draws the same sign for the same meaning.
        XCTAssertEqual(MoneyUpQuickAction.allCases.map(\.systemImage), [
            MoneyUpEntryGlyph.expense, MoneyUpEntryGlyph.income, MoneyUpEntryGlyph.transfer,
            MoneyUpEntryGlyph.refund, MoneyUpEntryGlyph.smartEntry, MoneyUpEntryGlyph.receipt
        ])
        typealias Card = QuickLogWidgetCard<EmptyView>
        for primary in MoneyUpQuickAction.allCases {
            XCTAssertTrue(Card.shortcuts(for: primary, family: .small, density: .standard).isEmpty)
            let medium = Card.shortcuts(for: primary, family: .medium, density: .standard)
            XCTAssertEqual(medium.count, 3)
            let large = Card.shortcuts(for: primary, family: .large, density: .standard)
            XCTAssertEqual(large.count, MoneyUpQuickAction.allCases.count - 1)
            XCTAssertFalse(medium.contains(primary) || large.contains(primary))
            // Pinned order never shifts with the chosen main action.
            let canonical = MoneyUpQuickAction.allCases.filter { $0 != primary }
            XCTAssertEqual(large, canonical)
            XCTAssertTrue(Card.shortcuts(for: primary, family: .medium, density: .accessibility).isEmpty)
            XCTAssertEqual(Card.shortcuts(for: primary, family: .large, density: .accessibility).count, 2)
        }
    }
}

extension QuickLogFavouriteAppTests {
    private func reportingMidnight(_ year: Int, _ month: Int, _ day: Int, zone: String) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    func testBudgetPaceFindsTodaysPlaceInTheMonthForEveryReportingZone() throws {
        for zone in ["Asia/Singapore", "Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC", "America/New_York"] {
            let end = try reportingMidnight(2026, 10, 1, zone: zone)
            let middle = try reportingMidnight(2026, 9, 16, zone: zone)
            let pace = try XCTUnwrap(BudgetPeriodPace.elapsedFraction(periodEnd: end, now: middle), zone)
            XCTAssertEqual(pace, 0.5, accuracy: 0.002, zone)
            XCTAssertNil(BudgetPeriodPace.elapsedFraction(periodEnd: end, now: end), zone)
            XCTAssertNil(BudgetPeriodPace.elapsedFraction(
                periodEnd: end, now: try reportingMidnight(2026, 8, 31, zone: zone)), zone)
        }
        // February in a leap year is 29 days, derived without the zone.
        let leapEnd = try reportingMidnight(2028, 3, 1, zone: "Asia/Singapore")
        let leapDay = try reportingMidnight(2028, 2, 29, zone: "Asia/Singapore")
        XCTAssertEqual(try XCTUnwrap(BudgetPeriodPace.elapsedFraction(periodEnd: leapEnd, now: leapDay)),
                       28.0 / 29.0, accuracy: 0.0001)
        XCTAssertFalse(BudgetPeriodPace.isAheadOfPace(percentUsed: 50, elapsed: 0.5))
        XCTAssertFalse(BudgetPeriodPace.isAheadOfPace(percentUsed: 54, elapsed: 0.5))
        XCTAssertTrue(BudgetPeriodPace.isAheadOfPace(percentUsed: 60, elapsed: 0.5))
    }

    func testBudgetStatusTimelineRedatesTheSameGenerationUntilExpiry() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiry = now.addingTimeInterval(2 * 86_400)
        let snapshot = MoneyUpWidgetPublishedSnapshot(
            budget: .available(percentUsed: 40, validUntil: expiry), insights: nil
        )
        let budget = MoneyUpWidgetTimelinePlanner.generations(
            startingAt: now, snapshot: snapshot, surface: .budgetStatus
        )
        XCTAssertEqual(budget.count, 1 + 7 + 1)
        XCTAssertEqual(budget.first?.date, now)
        XCTAssertEqual(budget.last?.date, expiry)
        XCTAssertEqual(budget.last?.snapshot.budget, .stale)
        XCTAssertTrue(budget.dropLast().allSatisfy { $0.snapshot == snapshot })
        XCTAssertEqual(zip(budget, budget.dropFirst()).filter { $0.date >= $1.date }.count, 0)
        // Smart Overview and Quick Log keep their existing two-point and
        // single-entry timelines.
        XCTAssertEqual(MoneyUpWidgetTimelinePlanner.generations(
            startingAt: now, snapshot: snapshot, surface: .smartOverview
        ).count, 2)
        XCTAssertEqual(MoneyUpWidgetTimelinePlanner.generations(
            startingAt: now, snapshot: snapshot, surface: .quickAction
        ).count, 1)
    }

    /// Visual evidence for review: every widget size in light and dark, a
    /// Chinese and an AX5 variant, the in-app page, and Log with favourites.
    @MainActor
    func testRenderQuickLogWidgetsQuickAccessAndFavouriteStrip() async throws {
        let sizes: [(QuickLogWidgetLayoutFamily, CGSize, String)] = [
            (.small, CGSize(width: 170, height: 170), "small"),
            (.medium, CGSize(width: 364, height: 170), "medium"),
            (.large, CGSize(width: 364, height: 382), "large")
        ]
        for (family, size, name) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                await capture(
                    QuickLogWidgetPreviewPanel(family: family, action: .expense),
                    name: "quick-log-widget-\(name)-\(scheme == .dark ? "dark" : "light")",
                    size: size, scheme: scheme
                )
            }
        }
        await capture(QuickLogWidgetPreviewPanel(family: .medium, action: .smartEntry),
                      name: "quick-log-widget-medium-smart-entry-zh", size: CGSize(width: 364, height: 170),
                      scheme: .light, language: .simplifiedChinese)
        await capture(
            VStack(alignment: .leading, spacing: 14) {
                ForEach([(35, 0.5), (62, 0.5), (112, 0.8)], id: \.0) { used, elapsed in
                    BudgetPaceBar(percentUsed: used, elapsed: elapsed)
                }
            }
            .padding(20).tint(Color.moneyUpAction),
            name: "budget-pace-bars", size: CGSize(width: 338, height: 120), scheme: .light
        )
        await capture(QuickLogWidgetCard(primary: .expense, family: .medium, density: .accessibility) {
                QuickLogWidgetTile(action: $0, role: $1)
            }
            .padding(16).environment(\.dynamicTypeSize, .accessibility5),
            name: "quick-log-widget-medium-ax5", size: CGSize(width: 364, height: 170), scheme: .light)

        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let favourites = [
            QuickLogFavourite(name: "Lunch", kind: .expense, accountID: fixture.wallet.id,
                              categoryID: fixture.food.id),
            QuickLogFavourite(name: "Coffee", kind: .expense, amount: Decimal(string: "3.2"),
                              accountID: fixture.wallet.id, categoryID: fixture.food.id),
            QuickLogFavourite(name: "Old card", kind: .expense, accountID: UUID())
        ]
        let profile = UserProfile(baseCurrency: fixture.sgd, quickLogFavourites: favourites)
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food])
        await capture(NavigationStack { WidgetsQuickAccessView() }.environment(model),
                      name: "quick-access-page", size: CGSize(width: 390, height: 1400), scheme: .light)
        await capture(
            QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false, isActive: false,
                launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in })
                .environment(model),
            name: "log-favourites-strip", size: CGSize(width: 390, height: 844), scheme: .light
        )
        XCTAssertTrue(model.entries.isEmpty)
        let emptyModel = fixture.model(profile: UserProfile(baseCurrency: fixture.sgd),
                                       accounts: [fixture.wallet, fixture.food])
        await capture(
            QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false, isActive: false,
                launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in })
                .environment(emptyModel),
            name: "log-favourites-empty", size: CGSize(width: 390, height: 844), scheme: .dark
        )
        let request = QuickLogRouteRequest(id: 1, ingressToken: UUID(), requiresIngressAcknowledgement: false,
                                           generation: 0, mode: .expense)
        await capture(LockedQuickCaptureView(request: request).environment(emptyModel),
                      name: "locked-capture", size: CGSize(width: 390, height: 844), scheme: .dark)
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }

    @MainActor
    private func capture<Content: View>(
        _ content: Content, name: String, size: CGSize, scheme: ColorScheme,
        language: AppLanguagePreference = .english
    ) async {
        let defaults = AppLanguagePreference.defaults
        let previous = defaults?.object(forKey: AppLanguagePreference.storageKey)
        defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppLanguagePreference.storageKey) }
            else { defaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        let view = content
            .frame(width: size.width, height: size.height)
            .background(Color.moneyUpBackground)
            .environment(\.locale, language.locale)
            .preferredColorScheme(scheme)
        let controller = UIHostingController(rootView: view)
        controller.safeAreaRegions = []
        controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, size.width)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
