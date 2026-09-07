import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class JourneyRecalculationTests: XCTestCase {
    @MainActor
    func testCompactBookRefreshesParentAndStandaloneTotalsImmediatelyAfterSaveEditAndUndo() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "Asia/Singapore")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23, minute: 59)))
        let child = LedgerAccount(name: "Dining", kind: .expense, parentID: fixture.food.id)
        let standalone = LedgerAccount(name: "Books", kind: .expense)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, child, standalone]
        let nodes = [BudgetNode(id: fixture.food.id, name: "Food", purpose: .flexible, allocationMode: .automatic),
            BudgetNode(id: child.id, parentID: fixture.food.id, name: "Dining", limit: try Money(100, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic),
            BudgetNode(id: standalone.id, name: "Books", limit: try Money(50, currency: fixture.sgd), purpose: .flexible, allocationMode: .automatic)]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: calendar.timeZone.identifier)
        let timeline = try BudgetConfigurationTimeline(currency: fixture.sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: try XCTUnwrap(calendar.dateInterval(of: .month, for: now)?.start), nodes: nodes)
        ])
        try await fixture.seed(profile: profile, accounts: accounts, budgetNodes: nodes, budgetConfigurationTimeline: timeline)
        let model = fixture.model(profile: profile, accounts: accounts, budgetNodes: nodes,
            retainsCompleteJournal: false, budgetConfigurationTimeline: timeline, currentDate: { now })
        try await model.reloadPersistedBookForTesting()
        let saved = try await model.logExpense(amount: 12.34, accountID: fixture.wallet.id,
            categoryID: child.id, occurredAt: now, payee: nil, note: nil)
        let id = try XCTUnwrap(saved)
        try assertTotals(model, parentID: fixture.food.id, parent: 87.66, standaloneID: standalone.id, standalone: 50, balance: -12.34, account: fixture.wallet)
        try await model.replaceEntry(id: id, kind: .expense, amount: 60, destinationAmount: nil,
            accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: standalone.id,
            occurredAt: now, payee: nil, note: nil)
        try assertTotals(model, parentID: fixture.food.id, parent: 100, standaloneID: standalone.id, standalone: -10, balance: -60, account: fixture.wallet)
        let edited = try XCTUnwrap(model.entries.first { $0.supersedesID == id })
        try await model.deleteEntry(id: edited.id)
        try assertTotals(model, parentID: fixture.food.id, parent: 100, standaloneID: standalone.id, standalone: 50, balance: 0, account: fixture.wallet)
        XCTAssertEqual(model.displayBalanceResult(for: fixture.usAccount).value?.amount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testOnboardingOpeningBalanceUsesTheUserActionClockAtMonthBoundary() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-02-29T23:59:59Z"))
        let model = fixture.model(accounts: [], currentDate: { now })
        model.state = .onboarding
        try await model.completeOnboarding(baseCurrencyCode: "SGD", accountName: "Cash",
            accountType: .cash, startingBalance: 5)
        let entries = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.occurredAt, now)
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    func testDueReminderRetainsOverdueOccurrenceAndSkipsPausedOrEndedSeries() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func schedule(_ offset: Double) throws -> ScheduledTransaction {
            try ScheduledTransaction(kind: .expense, name: "Review", amount: Money(5, currency: fixture.sgd),
                accountID: fixture.wallet.id, categoryAccountID: fixture.food.id,
                nextOccurrence: start.addingTimeInterval(offset), frequency: .monthly)
        }
        var paused = try schedule(-100)
        try paused.pause()
        var ended = try schedule(-200)
        try ended.end(at: start)
        let overdue = try schedule(0)
        let future = try schedule(100)
        XCTAssertEqual(ScheduledReviewPolicy.next(in: [future, paused, ended, overdue])?.id, overdue.id)
        XCTAssertNil(ScheduledReviewPolicy.next(in: [paused, ended]))
    }

    @MainActor
    private func assertTotals(_ model: AppModel, parentID: UUID, parent: Decimal,
        standaloneID: UUID, standalone: Decimal, balance: Decimal, account: LedgerAccount) throws {
        let progress = try XCTUnwrap(model.budgetProgressThisMonthResult().value)
        XCTAssertEqual(progress.first { $0.node.id == parentID }?.remaining?.amount, parent)
        XCTAssertEqual(progress.first { $0.node.id == standaloneID }?.remaining?.amount, standalone)
        XCTAssertEqual(model.displayBalanceResult(for: account).value?.amount, balance)
        let summary = try XCTUnwrap(model.budgetPlanSummaryThisMonthResult().value.flatMap { $0 })
        XCTAssertEqual(summary.remaining.amount, parent + standalone, "Child allocation must count once")
    }
}
