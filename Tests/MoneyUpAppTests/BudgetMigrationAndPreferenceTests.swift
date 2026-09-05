import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class BudgetMigrationAndPreferenceTests: XCTestCase {
    private func date(_ month: Int, _ day: Int = 1) throws -> Date {
        try XCTUnwrap(FinancialPeriodBoundary.gregorianCalendar().date(
            from: DateComponents(year: 2026, month: month, day: day, hour: 12)
        ))
    }

    @MainActor
    func testGroupingMigrationPreservesFixedCapsAndClosedRevisions() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date(9, 5), august = try date(8)
        let calendar = FinancialPeriodBoundary.gregorianCalendar()
        let augustStart = try XCTUnwrap(calendar.dateInterval(of: .month, for: august)?.start)
        let child = LedgerAccount(name: "Dining", kind: .expense, parentID: fixture.food.id)
        let legacyAmount = try XCTUnwrap(Decimal(string: "200.001"))
        let nodes = [BudgetNode(id: fixture.food.id, name: fixture.food.name),
                     BudgetNode(id: child.id, parentID: fixture.food.id, name: child.name, limit: try Money(legacyAmount, currency: fixture.sgd))]
        let timeline = try BudgetConfigurationTimeline(currency: fixture.sgd, revisions: [BudgetConfigurationRevision(effectiveMonth: augustStart, nodes: nodes)])
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food, child], budgetNodes: nodes, budgetConfigurationTimeline: timeline)
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food, child], budgetNodes: nodes, budgetConfigurationTimeline: timeline, currentDate: { now })
        try await model.prepareBudgetConfigurationTimelineAfterLoad(in: fixture.store, persistsMigration: true)
        XCTAssertEqual(model.budgetNodes.first { $0.id == fixture.food.id }?.allocationMode, .automatic)
        XCTAssertEqual(model.budgetNodes.first { $0.id == child.id }?.allocationMode, .fixedTotal)
        XCTAssertEqual(model.budgetConfigurationTimeline?.revision(effectiveAt: august).nodes.first { $0.id == fixture.food.id }?.allocationMode, .fixedTotal)
        let once = model.budgetConfigurationTimeline
        try await model.prepareBudgetConfigurationTimelineAfterLoad(in: fixture.store, persistsMigration: true)
        XCTAssertEqual(model.budgetConfigurationTimeline, once)
        // Classification must not round or reject an unchanged legacy amount.
        try await model.setMonthlyBudget(categoryID: child.id, date: now, currency: fixture.sgd,
            amount: legacyAmount, mode: .fixedTotal, purpose: .flexible)
        let saved = model.budgetNodes.first { $0.id == child.id }
        let month = try BudgetMonth(containing: now, calendar: calendar)
        XCTAssertEqual(saved?.resolved(for: month, currency: fixture.sgd).limit?.amount, legacyAmount)
        let older = try await model.monthlyBudgetPresentation(asOf: date(7), currency: fixture.sgd)
        guard case .unavailable(.budgetHistoryUnavailable) = older else { return XCTFail("No invented historical budget") }
        await fixture.store.close()
    }

    @MainActor
    func testAtomicMovePublishesNewParentsAndSurvivesReopen() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date(9, 5)
        let second = LedgerAccount(name: "Lifestyle", kind: .expense)
        let child = LedgerAccount(name: "Dining", kind: .expense, parentID: fixture.food.id)
        let nodes = [
            BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd), allocationMode: .automatic),
            BudgetNode(id: second.id, name: second.name, limit: try Money(200, currency: fixture.sgd), allocationMode: .automatic),
            BudgetNode(id: child.id, parentID: fixture.food.id, name: child.name, limit: try Money(50, currency: fixture.sgd), allocationMode: .automatic)
        ]
        let accounts = [fixture.wallet, fixture.food, second, child]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        let entry = try TransactionFactory.expense(amount: Money(60, currency: fixture.sgd), paidFrom: fixture.wallet.id, category: child.id, occurredAt: now)
        try await fixture.seed(profile: profile, accounts: accounts, entries: [entry], budgetNodes: nodes)
        let model = fixture.model(profile: profile, accounts: accounts, entries: [entry], budgetNodes: nodes, currentDate: { now })
        try await model.updateCategoryMetadata(categoryID: child.id, name: "Dining renamed", amount: 50, purpose: .flexible, rolloverRule: .none, parentChange: .set(second.id))
        let progress = try XCTUnwrap(model.budgetProgressThisMonthResult().value)
        XCTAssertEqual(progress.first { $0.node.id == fixture.food.id }?.remaining?.amount, 100)
        XCTAssertEqual(progress.first { $0.node.id == second.id }?.remaining?.amount, 190)
        XCTAssertEqual(progress.first { $0.node.id == child.id }?.remaining?.amount, -10)
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let storedAccount = try await reopened.fetch(LedgerAccount.self, id: child.id.uuidString, from: .accounts)
        let storedBudget = try await reopened.fetch(BudgetNode.self, id: child.id.uuidString, from: .budgetNodes)
        let storedEntry = try await reopened.fetch(JournalEntry.self, id: entry.id.uuidString, from: .journalEntries)
        XCTAssertEqual(storedAccount?.parentID, second.id)
        XCTAssertEqual(storedAccount?.name, "Dining renamed")
        XCTAssertEqual(storedBudget?.parentID, second.id)
        XCTAssertEqual(storedEntry, entry)
        await reopened.close()
    }

    @MainActor
    func testFailedPreferenceWriteRevertsOptimisticChoice() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        await fixture.store.close()
        model.changeDisplayPreferences { $0.showsDailyGuidance = false }
        XCTAssertFalse(model.displayPreferences.showsDailyGuidance)
        await model.displayPreferenceWriteTask?.value
        XCTAssertTrue(model.displayPreferences.showsDailyGuidance)
        XCTAssertNotNil(model.displayPreferenceFailure)
    }

    @MainActor
    func testImmediateLockDrainsLatestPreferenceWrite() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food])
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food])
        model.changeDisplayPreferences { $0.showsDailyGuidance = false }
        let write = model.displayPreferenceWriteTask
        model.lock()
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)
        await write?.value
        model.lock()
        await model.storeCloseTask?.value
        let reopened = try fixture.reopenStore()
        let saved = try await reopened.fetch(UserProfile.self, id: UserProfile.primaryRecordID, from: .profile)
        XCTAssertFalse(try XCTUnwrap(saved).displayPreferences.showsDailyGuidance)
        XCTAssertEqual(model.state, .locked)
        await reopened.close()
    }

    func testParentHistoryScopeIncludesChildrenButChartPresetStaysExact() {
        let parent = LedgerAccount(name: "Food", kind: .expense)
        let child = LedgerAccount(name: "Dining", kind: .expense, parentID: parent.id)
        var filters = HistoryFilterDraft()
        filters.categoryIDs = [parent.id]
        XCTAssertEqual(filters.query(searchText: "", accounts: [parent, child]).categoryIDs, [parent.id, child.id])
        let chart = HistoryFilterDraft(preset: HistoryPreset(categoryID: parent.id))
        XCTAssertEqual(chart.query(searchText: "", accounts: [parent, child]).categoryIDs, [parent.id])
        XCTAssertEqual(HistoryCategoryScope.expanded([], in: [parent, child]), [])
    }
}
