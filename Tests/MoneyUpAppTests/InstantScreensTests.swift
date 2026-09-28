import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

/// Screens keep what they show while newer data loads, and the loads they run
/// do no repeated work. These tests pin the model side of that behaviour.
final class InstantScreensTests: XCTestCase {
    /// Right after a save the bounded projection is rebuilding. That is a
    /// quiet "updating" state, never the "unlock and try again" failure.
    @MainActor
    func testRefreshingAReadyBookIsPendingNotAFailure() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(
            profile: UserProfile(baseCurrency: fixture.sgd),
            retainsCompleteJournal: false
        )
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.journalRefreshFallbackIssue, .refreshPending)
        XCTAssertTrue(DerivedValueIssue.refreshPending.isPending)
        XCTAssertTrue(DerivedValueIssue.budgetRefreshPending.isPending)
        XCTAssertFalse(DerivedValueIssue.appNotReady.isPending)
        guard case .unavailable(.refreshPending) = model.reportResult(for: .thisMonth) else {
            return XCTFail("A ready book's rebuilding report must read as pending")
        }
        // A real failure still wins over the pending state.
        model.journalDerivedRefreshIssue = .ledgerCalculationFailed
        XCTAssertEqual(model.journalRefreshFallbackIssue, .ledgerCalculationFailed)
        // A book that is not open is not "updating".
        XCTAssertEqual(AppModel().journalRefreshFallbackIssue, .appNotReady)
        await fixture.store.close()
    }

    /// Unfiltered History reads one page at a time; paging must still return
    /// every entry exactly once, in order, whatever the page size.
    @MainActor
    func testAdaptivePagesReturnEveryEntryOnceInOrder() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entries = try (0..<250).map { offset in
            try TransactionFactory.expense(
                amount: Money(Decimal(offset % 7 + 1), currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset * 60)),
                payee: offset.isMultiple(of: 5) ? "Café" : "Grocer"
            )
        }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: entries
        )
        let model = fixture.model(entries: entries)
        for (query, expected) in [(HistoryQuery(), 250), (HistoryQuery(searchText: "cafe"), 50)] {
            for limit in [1, 7, 80, 200] {
                var cursor: JournalEntryPageCursor?
                var loaded: [JournalEntry] = []
                repeat {
                    let page = try await model.historyPage(query: query, after: cursor, limit: limit)
                    XCTAssertLessThanOrEqual(page.entries.count, limit)
                    loaded.append(contentsOf: page.entries)
                    cursor = page.nextCursor
                } while cursor != nil
                XCTAssertEqual(loaded.count, expected, "limit \(limit)")
                XCTAssertEqual(Set(loaded.map(\.id)).count, expected, "limit \(limit) repeated an entry")
                XCTAssertEqual(loaded.map(\.occurredAt), loaded.map(\.occurredAt).sorted(by: >),
                               "limit \(limit) lost newest-first order")
            }
        }
        await fixture.store.close()
    }

    /// When the first page already holds every match, its rows give the same
    /// totals as the full scan, so History need not scan the range twice.
    @MainActor
    func testCompleteFirstPageTotalsEqualTheFullScan() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entries = try (0..<30).map { offset in
            try TransactionFactory.expense(
                amount: Money(Decimal(string: "\(offset).25")!, currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset * 3_600)),
                payee: offset.isMultiple(of: 3) ? "Café" : "Grocer"
            )
        }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: entries
        )
        let model = fixture.model(entries: entries)
        for query in [HistoryQuery(), HistoryQuery(searchText: "cafe"), HistoryQuery(searchText: "nothing")] {
            let page = try await model.historyPage(query: query)
            XCTAssertNil(page.nextCursor, "30 entries fit one page")
            let fromPage = try await model.historySummary(query: query, completeEntries: page.entries)
            let fromScan = try await model.historySummary(query: query)
            XCTAssertEqual(fromPage.transactionCount, fromScan.transactionCount)
            XCTAssertEqual(fromPage.amountsByCurrency, fromScan.amountsByCurrency)
        }
        await fixture.store.close()
    }

    /// The reporting calendar is cached per zone and follows a zone change.
    @MainActor
    func testReportingCalendarFollowsTheReportingZone() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(profile: UserProfile(
            baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore"
        ))
        XCTAssertEqual(model.reportingCalendar.timeZone.identifier, "Asia/Singapore")
        XCTAssertEqual(model.reportingCalendar, model.reportingCalendar)
        var profile = try XCTUnwrap(model.profile)
        profile.reportingTimeZoneIdentifier = "America/New_York"
        model.profile = profile
        XCTAssertEqual(model.reportingCalendar.timeZone.identifier, "America/New_York")
        XCTAssertEqual(
            model.reportingCalendar,
            FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "America/New_York")
        )
    }

    /// Language bundles are cached; lookups stay exact in both languages.
    func testCachedLanguageBundlesReturnTheSameStrings() {
        for _ in 0..<3 {
            XCTAssertEqual(AppLocalization.string("tab.log", language: .english), "Log")
            XCTAssertEqual(AppLocalization.string("tab.log", language: .simplifiedChinese), "记账")
            XCTAssertEqual(AppLocalization.string("derived.updating", language: .simplifiedChinese), "正在更新")
        }
        XCTAssertIdentical(AppLanguagePreference.defaults, AppLanguagePreference.defaults)
    }
}
