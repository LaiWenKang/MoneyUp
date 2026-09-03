import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

/// Covers the Today board's stored pins and the derived month/week/day
/// figures it publishes, plus the book-wide rule that decides whether an
/// amount is written with a symbol or an ISO code.
final class PinnedBudgetBoardTests: XCTestCase {
    private let reportingZone = "UTC"

    private func reportingCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") { calendar.timeZone = utc }
        return calendar
    }

    private func midMonth() throws -> Date {
        try XCTUnwrap(
            reportingCalendar().date(
                from: DateComponents(year: 2026, month: 9, day: 2, hour: 12)
            )
        )
    }

    private func profile(
        currency: CurrencyCode,
        pinned: [UUID] = []
    ) -> UserProfile {
        UserProfile(
            baseCurrency: currency,
            reportingTimeZoneIdentifier: reportingZone,
            pinnedBudgetNodeIDs: pinned
        )
    }

    @MainActor
    func testPinningKeepsChosenOrderAndStopsAtTheBoardLimit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let nodes = (0...UserProfile.maximumPinnedBudgetNodes).map { index in
            BudgetNode(name: "Category \(index)")
        }
        let stored = profile(currency: fixture.sgd)
        try await fixture.seed(
            profile: stored,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            budgetNodes: nodes
        )
        let model = fixture.model(profile: stored, budgetNodes: nodes)

        for node in nodes.prefix(UserProfile.maximumPinnedBudgetNodes) {
            try await model.setBudgetNodePinned(node.id, isPinned: true)
        }

        XCTAssertEqual(
            model.profile?.pinnedBudgetNodeIDs,
            nodes.prefix(UserProfile.maximumPinnedBudgetNodes).map(\.id)
        )
        XCTAssertFalse(model.canPinAnotherBudgetNode)

        // One past the cap is refused rather than silently evicting a pin the
        // user deliberately placed.
        do {
            try await model.setBudgetNodePinned(nodes[nodes.count - 1].id, isPinned: true)
            XCTFail("Expected the board limit to reject an extra pin")
        } catch AppModelError.invalidBook {
            XCTAssertEqual(
                model.profile?.pinnedBudgetNodeIDs.count,
                UserProfile.maximumPinnedBudgetNodes
            )
        }

        // Re-pinning an existing pin is a no-op, not a duplicate or an error.
        try await model.setBudgetNodePinned(nodes[0].id, isPinned: true)
        XCTAssertEqual(
            model.profile?.pinnedBudgetNodeIDs.count,
            UserProfile.maximumPinnedBudgetNodes
        )

        try await model.setBudgetNodePinned(nodes[0].id, isPinned: false)
        XCTAssertEqual(model.profile?.pinnedBudgetNodeIDs.first, nodes[1].id)
        XCTAssertTrue(model.canPinAnotherBudgetNode)
        await fixture.store.close()
    }

    @MainActor
    func testCategoryOutsideTheBudgetCannotBePinnedAndIsDroppedOnReplace() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let known = BudgetNode(id: fixture.food.id, name: fixture.food.name)
        let unknown = UUID()
        let stored = profile(currency: fixture.sgd)
        try await fixture.seed(
            profile: stored,
            accounts: [fixture.wallet, fixture.food],
            budgetNodes: [known]
        )
        let model = fixture.model(profile: stored, budgetNodes: [known])

        do {
            try await model.setBudgetNodePinned(unknown, isPinned: true)
            XCTFail("Expected an unknown category to be rejected")
        } catch AppModelError.missingRecord {
            XCTAssertTrue(model.profile?.pinnedBudgetNodeIDs.isEmpty == true)
        }

        try await model.updatePinnedBudgetNodes([unknown, known.id, unknown])

        XCTAssertEqual(model.profile?.pinnedBudgetNodeIDs, [known.id])
        XCTAssertEqual(model.pinnedBudgetNodes.map(\.id), [known.id])
        await fixture.store.close()
    }

    @MainActor
    func testPinnedSummarySplitsWhatIsLeftAcrossMonthWeekAndDay() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let asOf = try midMonth()
        let node = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(400, currency: fixture.sgd),
            purpose: .flexible
        )
        let stored = profile(currency: fixture.sgd, pinned: [node.id])
        let entry = try fixture.expense(amount: 90, occurredAt: asOf)
        try await fixture.seed(
            profile: stored,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [entry],
            budgetNodes: [node]
        )
        let model = fixture.model(
            profile: stored,
            entries: [entry],
            budgetNodes: [node],
            currentDate: { asOf }
        )

        guard case let .available(summaries) = model.pinnedBudgetSummariesResult(
            asOf: asOf
        ) else {
            return XCTFail("Expected the pinned board to resolve")
        }
        let summary = try XCTUnwrap(summaries.first)
        let spread = try XCTUnwrap(summary.spread)

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summary.node.id, node.id)
        XCTAssertEqual(summary.purpose, .flexible)
        XCTAssertFalse(summary.isOverspent)
        // The month bucket is exactly what the budget says is left; the shorter
        // horizons are apportionments of that same figure, never larger.
        XCTAssertEqual(spread.monthly.available, summary.remaining)
        XCTAssertLessThanOrEqual(
            spread.daily.available.amount,
            spread.weekly.available.amount
        )
        XCTAssertLessThanOrEqual(
            spread.weekly.available.amount,
            spread.monthly.available.amount
        )
        XCTAssertEqual(spread.daily.available.currency, fixture.sgd)
        // 400 budgeted less 90 spent, apportioned over the 29 reporting days
        // that remain on 2 September 2026.
        XCTAssertEqual(summary.remaining?.amount, 310)
        XCTAssertEqual(spread.daily.remainingDayCount, 29)
        XCTAssertEqual(spread.daily.available.amount, Decimal(string: "10.69"))
        XCTAssertEqual(spread.weekly.available.amount, Decimal(string: "74.83"))
        await fixture.store.close()
    }

    @MainActor
    func testOverspentPinReportsItsOverspendInsteadOfANegativePace() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let asOf = try midMonth()
        let node = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(50, currency: fixture.sgd),
            purpose: .flexible
        )
        let stored = profile(currency: fixture.sgd, pinned: [node.id])
        let entry = try fixture.expense(amount: 120, occurredAt: asOf)
        try await fixture.seed(
            profile: stored,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [entry],
            budgetNodes: [node]
        )
        let model = fixture.model(
            profile: stored,
            entries: [entry],
            budgetNodes: [node],
            currentDate: { asOf }
        )

        guard case let .available(summaries) = model.pinnedBudgetSummariesResult(
            asOf: asOf
        ), let summary = summaries.first else {
            return XCTFail("Expected the pinned board to resolve")
        }

        XCTAssertNil(summary.spread)
        XCTAssertTrue(summary.isOverspent)
        XCTAssertEqual(summary.remaining?.amount, -70)
        await fixture.store.close()
    }

    @MainActor
    func testMoneyDisplayPolicyNamesOnlyTheCurrenciesThatCollide() throws {
        defer { MoneyDisplayPolicy.reset() }
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let locale = Locale(identifier: "en_SG")

        MoneyDisplayPolicy.update(
            preference: .automatic,
            currenciesInUse: [sgd],
            locale: locale
        )
        XCTAssertEqual(MoneyDisplayPolicy.notation(for: sgd), .symbol)
        XCTAssertFalse(MoneyDisplayPolicy.namesAccountCurrency)

        MoneyDisplayPolicy.update(
            preference: .code,
            currenciesInUse: [sgd, usd],
            locale: locale
        )
        XCTAssertEqual(MoneyDisplayPolicy.notation(for: sgd), .code)
        XCTAssertEqual(MoneyDisplayPolicy.notation(for: usd), .code)
        XCTAssertTrue(MoneyDisplayPolicy.namesAccountCurrency)

        MoneyDisplayPolicy.update(
            preference: .symbol,
            currenciesInUse: [sgd, usd],
            locale: locale
        )
        XCTAssertEqual(MoneyDisplayPolicy.notation(for: sgd), .symbol)
        XCTAssertEqual(MoneyDisplayPolicy.notation(for: usd), .symbol)

        MoneyDisplayPolicy.reset()
        XCTAssertEqual(MoneyDisplayPolicy.preference, .automatic)
        XCTAssertTrue(MoneyDisplayPolicy.ambiguousCurrencies.isEmpty)
        XCTAssertFalse(MoneyDisplayPolicy.namesAccountCurrency)
    }

    @MainActor
    func testAccountLabelNamesItsCurrencyOnlyInAMultiCurrencyBook() throws {
        defer { MoneyDisplayPolicy.reset() }
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let account = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)

        MoneyDisplayPolicy.update(preference: .automatic, currenciesInUse: [sgd])
        XCTAssertEqual(accountCurrencyLabel(account), "Wallet")

        MoneyDisplayPolicy.update(
            preference: .automatic,
            currenciesInUse: [sgd, usd]
        )
        XCTAssertEqual(accountCurrencyLabel(account), "Wallet · SGD")

        // A category has no currency of its own, so it is never annotated.
        XCTAssertEqual(
            accountCurrencyLabel(LedgerAccount(name: "Food", kind: .expense)),
            "Food"
        )
    }

    @MainActor
    func testBookCurrencyInventoryCoversAccountsHoldingsAndSavedRates() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let myr = try CurrencyCode("MYR")
        let jpy = try CurrencyCode("JPY")
        let brokerage = LedgerAccount(
            name: "Brokerage",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "NKY",
            name: "Nikkei fund",
            quantity: 1,
            price: try Money(100, currency: jpy)
        )
        let rate = try DatedExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: myr,
            rate: try XCTUnwrap(Decimal(string: "3.4")),
            effectiveAt: try midMonth(),
            calendar: reportingCalendar(),
            timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )
        let stored = profile(currency: fixture.sgd)
        try await fixture.seed(
            profile: stored,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food, brokerage]
        )
        let model = fixture.model(
            profile: stored,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food, brokerage],
            investmentHoldings: [holding],
            exchangeRates: [rate]
        )

        XCTAssertEqual(
            model.currenciesInUse,
            Set([fixture.sgd, fixture.usd, myr, jpy])
        )
        await fixture.store.close()
    }
}
