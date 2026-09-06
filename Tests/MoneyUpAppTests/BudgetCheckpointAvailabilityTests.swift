import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class BudgetCheckpointAvailabilityTests: XCTestCase {
    private let calendar = FinancialPeriodBoundary.gregorianCalendar(
        timeZoneIdentifier: "Asia/Singapore"
    )

    private func date(_ month: Int, day: Int = 1) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: month, day: day
        )))
    }

    @MainActor
    func testCurrentCheckpointUsesExactSignedCarryWithoutHistoryProjection() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let month = try date(9)
        let now = try date(9, day: 6)
        let sourceID = UUID()
        let node = BudgetNode(
            id: fixture.food.id, name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd), purpose: .flexible,
            rolloverRule: .fullBalance, rolloverStartedAt: try date(8)
        )
        for carry: Decimal in [-130, -30, 0, 45] {
            let timeline = try BudgetConfigurationTimeline(
                currency: fixture.sgd,
                revisions: [BudgetConfigurationRevision(
                    effectiveMonth: month, nodes: [node],
                    carryMappings: [BudgetCarryMapping(sourceID: sourceID, targetID: node.id)],
                    openingCarry: [sourceID: try Money(carry, currency: fixture.sgd)]
                )]
            )
            let model = fixture.model(
                profile: UserProfile(baseCurrency: fixture.sgd,
                                     reportingTimeZoneIdentifier: "Asia/Singapore"),
                budgetNodes: [node], retainsCompleteJournal: false,
                budgetConfigurationTimeline: timeline, currentDate: { now }
            )
            XCTAssertNil(model.closedMonthBudgetProjection)
            let tree = try model.reportingBudgetTree(currency: fixture.sgd)
            let result = try model.currentBudgetRolloverSnapshot(tree: tree)
            XCTAssertEqual(result.effectiveLimits[node.id]?.amount, 100 + carry)
            XCTAssertEqual(result.effectiveLimits[node.id]?.currency, fixture.sgd)
            XCTAssertEqual(result.carryIn[node.id]?.amount ?? 0, carry)
            XCTAssertNil(result.carryIn[sourceID])
            XCTAssertNil(model.journalDerivedRefreshTask)
            XCTAssertEqual(model.budgetConfigurationTimeline, timeline)
        }
        await fixture.store.close()
    }

    @MainActor
    func testCurrentZeroCheckpointAndNewRolloverDoNotRequireClosedMonthReads() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let month = try date(9)
        let now = try date(9, day: 6)
        for rule: BudgetRolloverRule in [.none, .positiveOnly, .fullBalance] {
            let node = BudgetNode(
                id: fixture.food.id, name: fixture.food.name,
                limit: try Money(100, currency: fixture.sgd), purpose: .flexible,
                rolloverRule: rule, rolloverStartedAt: month
            )
            for checkpoint: [UUID: Money]? in [nil, [:]] {
                let timeline = try BudgetConfigurationTimeline(
                    currency: fixture.sgd,
                    revisions: [BudgetConfigurationRevision(
                        effectiveMonth: month, nodes: [node], openingCarry: checkpoint
                    )]
                )
                let model = fixture.model(
                    profile: UserProfile(baseCurrency: fixture.sgd,
                                         reportingTimeZoneIdentifier: "Asia/Singapore"),
                    budgetNodes: [node], retainsCompleteJournal: false,
                    budgetConfigurationTimeline: timeline, currentDate: { now }
                )
                let tree = try model.reportingBudgetTree(currency: fixture.sgd)
                let result = try model.currentBudgetRolloverSnapshot(tree: tree)
                XCTAssertEqual(result.effectiveLimits[node.id]?.amount, 100)
                XCTAssertTrue(result.carryIn.isEmpty)
                XCTAssertNil(model.journalDerivedRefreshTask)
            }
        }
        await fixture.store.close()
    }

    @MainActor
    func testOlderCheckpointStillRequiresCompleteHistoryAndAppliesActualSpending() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let august = try date(8)
        let september = try date(9)
        let now = try date(9, day: 6)
        let node = BudgetNode(
            id: fixture.food.id, name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd), purpose: .flexible,
            rolloverRule: .fullBalance, rolloverStartedAt: august
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: august, nodes: [node],
                openingCarry: [node.id: try Money(25, currency: fixture.sgd)]
            )]
        )
        let model = fixture.model(
            profile: UserProfile(baseCurrency: fixture.sgd,
                                 reportingTimeZoneIdentifier: "Asia/Singapore"),
            budgetNodes: [node], retainsCompleteJournal: false,
            budgetConfigurationTimeline: timeline, currentDate: { now }
        )
        // Hold refresh scheduling so this test controls projection publication.
        model.isWorking = true
        let tree = try model.reportingBudgetTree(currency: fixture.sgd)
        XCTAssertThrowsError(try model.currentBudgetRolloverSnapshot(tree: tree))
        XCTAssertTrue(model.journalDerivedRefreshWasDeferred)
        model.closedMonthBudgetProjection = ClosedMonthBudgetProjection(
            reportingTimeZoneIdentifier: calendar.timeZone.identifier,
            currentMonthStart: september, coverageStart: august,
            currency: fixture.sgd,
            monthlySpending: [MonthlyBudgetSpending(
                monthStart: august,
                directSpending: [node.id: try Money(140, currency: fixture.sgd)]
            )]
        )
        let result = try model.currentBudgetRolloverSnapshot(tree: tree)
        XCTAssertEqual(result.carryIn[node.id]?.amount, -15)
        XCTAssertEqual(result.effectiveLimits[node.id]?.amount, 85)
        await fixture.store.close()
    }

    @MainActor
    func testUpgradeCategoryEditsAndRepinningSurviveDelayedRefreshAndReopen() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date(9, day: 6)
        let child = LedgerAccount(name: "Dining", kind: .expense, parentID: fixture.food.id)
        let nodes = [
            BudgetNode(id: fixture.food.id, name: fixture.food.name),
            BudgetNode(id: child.id, parentID: fixture.food.id, name: child.name,
                       limit: try Money(100, currency: fixture.sgd), purpose: .flexible,
                       rolloverRule: .fullBalance, rolloverStartedAt: try date(8))
        ]
        let entries = try [
            TransactionFactory.expense(amount: Money(130, currency: fixture.sgd),
                paidFrom: fixture.wallet.id, category: child.id, occurredAt: date(8, day: 15)),
            TransactionFactory.expense(amount: Money(20, currency: fixture.sgd),
                paidFrom: fixture.wallet.id, category: child.id, occurredAt: now)
        ]
        let profile = UserProfile(baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Asia/Singapore", pinnedBudgetNodeIDs: [child.id])
        let accounts = [fixture.wallet, fixture.food, child]
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes)
        let gate = BudgetProjectionPublicationGate()
        let model = fixture.model(profile: profile, accounts: accounts,
            budgetNodes: nodes, lifecycleHooks: AppModelLifecycleHooks { checkpoint in
                if checkpoint == .afterJournalProjectionReadBeforePublish { await gate.suspendIfArmed() }
            }, retainsCompleteJournal: false, currentDate: { now })
        do {
            try await model.reloadPersistedBookForTesting()
            XCTAssertEqual(model.budgetNodes.first { $0.id == fixture.food.id }?.allocationMode, .automatic)
            XCTAssertEqual(model.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 50)
            await gate.arm()
            let newParentID = try await model.addCategory(name: "New category", kind: .expense)
            XCTAssertNil(model.closedMonthBudgetProjection)
            try await model.updateCategoryMetadata(categoryID: child.id, name: "Meals",
                amount: 120, purpose: .flexible, rolloverRule: .fullBalance,
                parentChange: .set(newParentID))
            try await model.setBudgetNodePinned(child.id, isPinned: false)
            try await model.setBudgetNodePinned(child.id, isPinned: true)
            let tree = try model.reportingBudgetTree(currency: fixture.sgd)
            XCTAssertEqual(try model.currentBudgetRolloverSnapshot(tree: tree).effectiveLimits[child.id]?.amount, 90)
            await gate.release()
            while let refresh = model.journalDerivedRefreshTask { await refresh.value }
            XCTAssertEqual(model.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 70)
            let plan = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
            XCTAssertEqual(plan.value?.summary?.remaining.amount, 70)
            XCTAssertEqual(plan.value?.progress.first { $0.node.id == child.id }?.node.parentID, newParentID)
            XCTAssertTrue(model.recoveryIssues.isEmpty)
        } catch {
            await gate.release()
            while let refresh = model.journalDerivedRefreshTask { await refresh.value }
            await fixture.store.close()
            throw error
        }
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let restored = fixture.model(store: reopened, retainsCompleteJournal: false, currentDate: { now })
        try await restored.reloadPersistedBookForTesting()
        XCTAssertEqual(restored.profile?.pinnedBudgetNodeIDs, [child.id])
        XCTAssertEqual(restored.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 70)
        let restoredPlan = await restored.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
        XCTAssertEqual(restoredPlan.value?.summary?.remaining.amount, 70)
        XCTAssertEqual(restored.accountsByID[child.id]?.name, "Meals")
        XCTAssertTrue(restored.recoveryIssues.isEmpty)
        let storedEntries = try await reopened.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(Set(storedEntries.map(\.id)), Set(entries.map(\.id)))
        for entry in entries { XCTAssertEqual(storedEntries.first { $0.id == entry.id }, entry) }
        await reopened.close()
    }
}

private actor BudgetProjectionPublicationGate {
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }

    func suspendIfArmed() async {
        guard armed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        armed = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
