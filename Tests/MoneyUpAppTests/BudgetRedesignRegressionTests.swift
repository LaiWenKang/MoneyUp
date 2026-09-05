import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class BudgetRedesignRegressionTests: XCTestCase {
    private func date(_ month: Int = 9) throws -> Date {
        try XCTUnwrap(FinancialPeriodBoundary.gregorianCalendar().date(
            from: DateComponents(year: 2026, month: month, day: 5, hour: 12)
        ))
    }

    @MainActor
    func testMonthlyEditsRefreshAncestorsAndPersistAfterReopen() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        let child = LedgerAccount(name: "Groceries", kind: .expense, parentID: fixture.food.id)
        let nodes = [
            BudgetNode(id: fixture.food.id, name: "Food", allocationMode: .automatic),
            BudgetNode(id: child.id, parentID: fixture.food.id, name: child.name, allocationMode: .automatic)
        ]
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, child]
        let entry = try TransactionFactory.expense(amount: Money(120, currency: fixture.sgd), paidFrom: fixture.wallet.id, category: child.id, occurredAt: now)
        try await fixture.seed(profile: profile, accounts: accounts, entries: [entry], budgetNodes: nodes)
        let model = fixture.model(profile: profile, accounts: accounts, entries: [entry], budgetNodes: nodes, currentDate: { now })
        try await model.setMonthlyBudget(categoryID: child.id, date: now, currency: fixture.sgd, amount: 300, mode: .automatic, purpose: .flexible)
        XCTAssertEqual(model.budgetPlanSummaryThisMonthResult().value.flatMap { $0 }?.limit.amount, 300)
        try await model.setMonthlyBudget(categoryID: child.id, date: now, currency: fixture.sgd, amount: 50, mode: .automatic, purpose: .flexible)
        let current = try XCTUnwrap(model.budgetProgressThisMonthResult().value)
        XCTAssertEqual(current.first { $0.node.id == fixture.food.id }?.remaining?.amount, -70)
        XCTAssertEqual(current.first { $0.node.id == child.id }?.remaining?.amount, -70)
        try await model.setMonthlyBudget(categoryID: child.id, date: now, currency: fixture.usd, amount: 80, mode: .automatic, purpose: .flexible)
        let foreign = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.usd)
        XCTAssertEqual(foreign.value?.summary?.limit.amount, 80)
        XCTAssertEqual(foreign.value?.summary?.spent.amount, 0)
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let storedNodes = try await reopened.fetchAll(BudgetNode.self, from: .budgetNodes)
        let storedTimeline = try await reopened.fetch(BudgetConfigurationTimeline.self, id: BudgetConfigurationTimeline.primaryRecordID, from: .budgetConfigurationTimelines)
        let restored = fixture.model(store: reopened, profile: profile, accounts: accounts, entries: [entry], budgetNodes: storedNodes, budgetConfigurationTimeline: storedTimeline, currentDate: { now })
        XCTAssertEqual(restored.budgetProgressThisMonthResult().value?.first { $0.node.id == fixture.food.id }?.remaining?.amount, -70)
        let restoredForeign = await restored.monthlyBudgetPresentation(asOf: now, currency: fixture.usd)
        XCTAssertEqual(restoredForeign.value?.summary?.limit.amount, 80)
        await reopened.close()
    }

    @MainActor
    func testCombinedMetadataAndInvalidParentLeaveNoPartialSave() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], budgetNodes: [node])
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food], budgetNodes: [node])
        do {
            try await model.updateCategoryMetadata(categoryID: node.id, name: "Should not save", amount: 900, purpose: .flexible, rolloverRule: .none, parentChange: .set(node.id))
            XCTFail("Self-parenting must reject the whole edit")
        } catch AppModelError.invalidCategoryParent {}
        let stored = try await fixture.store.fetch(BudgetNode.self, id: node.id.uuidString, from: .budgetNodes)
        let audits = try await fixture.store.count(in: .accountLifecycleAudit)
        XCTAssertEqual(stored, node)
        XCTAssertEqual(model.accountsByID[node.id]?.name, fixture.food.name)
        XCTAssertEqual(audits, 0)
        await fixture.store.close()
    }

    @MainActor
    func testConfiguredUnusedCategoryCanBeDeletedAndPinsAreRemoved() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd), purpose: .flexible)
        let profile = UserProfile(baseCurrency: fixture.sgd, pinnedBudgetNodeIDs: [node.id])
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], budgetNodes: [node])
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food], budgetNodes: [node])
        XCTAssertFalse(model.lifecycleImpact(for: node.id).isUnused)
        XCTAssertTrue(model.lifecycleImpact(for: node.id).canDeleteWithoutReassignment)
        try await model.deleteLedgerItem(id: node.id)
        XCTAssertNil(model.accountsByID[node.id])
        XCTAssertTrue(model.profile?.pinnedBudgetNodeIDs.isEmpty == true)
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let stored = try await reopened.fetch(LedgerAccount.self, id: node.id.uuidString, from: .accounts)
        let storedProfile = try await reopened.fetch(UserProfile.self, id: UserProfile.primaryRecordID, from: .profile)
        XCTAssertNil(stored)
        XCTAssertTrue(storedProfile?.pinnedBudgetNodeIDs.isEmpty == true)
        await reopened.close()
    }

    @MainActor
    func testParentChildMergeConservesBudgetAndReassignsSplitDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let child = LedgerAccount(name: "Dining", kind: .expense, parentID: fixture.food.id)
        let nodes = [
            BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(500, currency: fixture.sgd)),
            BudgetNode(id: child.id, parentID: fixture.food.id, name: child.name, limit: try Money(200, currency: fixture.sgd))
        ]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT", pinnedBudgetNodeIDs: [child.id])
        let draft = QuickLogDraft(kind: .expense, amountText: "10", destinationAmountText: "", accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: nil, occurredAt: now, dateWasEdited: true, payee: "", note: "Keep", smartText: "", splitLines: [QuickLogSplitDraftLine(categoryID: child.id, amountText: "10")])
        let accounts = [fixture.wallet, fixture.food, child]
        try await fixture.seed(profile: profile, accounts: accounts, budgetNodes: nodes, quickLogDraft: draft)
        let model = fixture.model(profile: profile, accounts: accounts, budgetNodes: nodes, quickLogDraft: draft, currentDate: { now })
        XCTAssertEqual(model.lifecycleImpact(for: child.id).draftReferenceCount, 1)
        try await model.mergeLedgerItem(id: child.id, into: fixture.food.id)
        XCTAssertEqual(model.budgetPlanSummaryThisMonthResult().value.flatMap { $0 }?.limit.amount, 500)
        XCTAssertEqual(model.quickLogDraft?.splitLines.first?.categoryID, fixture.food.id)
        XCTAssertEqual(model.quickLogDraft?.note, "Keep")
        XCTAssertEqual(model.profile?.pinnedBudgetNodeIDs, [fixture.food.id])
        await fixture.store.close()
    }

    @MainActor
    func testRapidVisibilityChangesPersistLastChoiceWithoutChangingBudget() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd), purpose: .flexible)
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], budgetNodes: [node])
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food], budgetNodes: [node])
        let before = model.budgetPlanSummaryThisMonthResult().value
        model.changeDisplayPreferences { $0.showsDailyGuidance = false }
        XCTAssertFalse(model.displayPreferences.showsDailyGuidance)
        model.changeDisplayPreferences { $0.showsDailyGuidance = true }
        model.changeDisplayPreferences { $0.setGuidanceVisible(false, for: node.id) }
        await model.displayPreferenceWriteTask?.value
        XCTAssertTrue(model.displayPreferences.showsDailyGuidance)
        XCTAssertFalse(model.displayPreferences.showsGuidance(for: node.id))
        XCTAssertEqual(model.budgetNodes, [node])
        XCTAssertEqual(model.budgetPlanSummaryThisMonthResult().value, before)
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let saved = try await reopened.fetch(UserProfile.self, id: UserProfile.primaryRecordID, from: .profile)
        XCTAssertTrue(saved?.displayPreferences.showsDailyGuidance == true)
        XCTAssertTrue(saved?.displayPreferences.hiddenGuidanceCategoryIDs.contains(node.id) == true)
        await reopened.close()
    }

    func testCurrencyOnlyHistoryFilterIsVisibleAndCounted() throws {
        var filters = HistoryFilterDraft()
        filters.categoryPostingCurrency = try CurrencyCode("USD")
        XCTAssertTrue(filters.hasActiveFilters)
        XCTAssertEqual(filters.activeFilterCount, 1)
        filters = HistoryFilterDraft()
        XCTAssertEqual(filters.activeFilterCount, 0)
    }
}
