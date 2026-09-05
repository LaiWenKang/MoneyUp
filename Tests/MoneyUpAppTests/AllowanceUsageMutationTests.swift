@testable import MoneyUp
import Foundation
import MoneyUpCore
import XCTest

final class AllowanceUsageMutationTests: XCTestCase {
    @MainActor
    func testEditPreservesIdentityAndRejectsStaleOrInvalidRevisionState()
        async throws {
        let setup = try makeSetup()
        defer { setup.fixture.removeFiles() }
        let original = setup.usage

        try await setup.model.updateUnlinkedBenefitAllowanceUsage(
            planID: setup.plan.id,
            expectedUsage: original,
            expectedPolicyRevisionID: setup.policyID,
            amount: 25,
            categoryID: setup.fixture.food.id,
            occurredAt: setup.occurredAt,
            note: "Corrected"
        )
        let updated = try XCTUnwrap(setup.model.allowancePlans.first?.usages.first)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.amount.amount, 25)
        XCTAssertEqual(updated.note, "Corrected")
        let fetchedStored = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.plan.id.uuidString,
            from: .allowancePlans
        )
        let stored = try XCTUnwrap(fetchedStored)
        XCTAssertEqual(stored.usages, [updated])

        do {
            try await setup.model.updateUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                expectedUsage: original,
                expectedPolicyRevisionID: setup.policyID,
                amount: 30,
                categoryID: setup.fixture.food.id,
                occurredAt: setup.occurredAt,
                note: nil
            )
            XCTFail("A stale usage value must fail its optimistic precondition")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        XCTAssertEqual(setup.model.allowancePlans.first?.usages, [updated])
        let unchangedStored = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.plan.id.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(
            unchangedStored?.usages,
            [updated]
        )
        await setup.fixture.store.close()
    }

    @MainActor
    func testEditRejectsDateCategoryRevisionAndCapacityWithoutMutation()
        async throws {
        let setup = try makeSetup()
        defer { setup.fixture.removeFiles() }
        try await setup.fixture.store.upsert(
            setup.plan,
            id: setup.plan.id.uuidString,
            in: .allowancePlans
        )
        let cases: [(Decimal, UUID?, Date, UUID)] = [
            (
                30,
                setup.fixture.food.id,
                setup.plan.startsAt.addingTimeInterval(-1),
                setup.policyID
            ),
            (30, setup.fixture.usAccount.id, setup.occurredAt, setup.policyID),
            (30, setup.fixture.food.id, setup.occurredAt, UUID()),
            (101, setup.fixture.food.id, setup.occurredAt, setup.policyID)
        ]

        for (amount, categoryID, occurredAt, policyID) in cases {
            do {
                try await setup.model.updateUnlinkedBenefitAllowanceUsage(
                    planID: setup.plan.id,
                    expectedUsage: setup.usage,
                    expectedPolicyRevisionID: policyID,
                    amount: amount,
                    categoryID: categoryID,
                    occurredAt: occurredAt,
                    note: nil
                )
                XCTFail("Invalid usage mutation must fail before publication")
            } catch {
                XCTAssertTrue(error is AppModelError)
            }
        }
        let stored = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.plan.id.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(setup.model.allowancePlans, [setup.plan])
        XCTAssertEqual(stored, setup.plan)
        await setup.fixture.store.close()
    }

    @MainActor
    func testDeleteRemovesExactlyOneAndUndoRestoresExactEvidence() async throws {
        let setup = try makeSetup()
        defer { setup.fixture.removeFiles() }

        let deleted = try await setup.model.deleteUnlinkedBenefitAllowanceUsage(
            planID: setup.plan.id,
            expectedUsage: setup.usage
        )
        XCTAssertEqual(deleted, setup.usage)
        XCTAssertEqual(setup.model.allowancePlans.first?.usages, [])
        let storedAfterDelete = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.plan.id.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(
            storedAfterDelete?.usages,
            []
        )

        try await setup.model.restoreDeletedUnlinkedBenefitAllowanceUsage(
            planID: setup.plan.id,
            deletedUsage: deleted,
            expectedPolicyRevisionID: setup.policyID
        )
        XCTAssertEqual(setup.model.allowancePlans.first?.usages, [setup.usage])
        let storedAfterUndo = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.plan.id.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(
            storedAfterUndo?.usages,
            [setup.usage]
        )
        await setup.fixture.store.close()
    }

    @MainActor
    func testUndoFailsWhenNewUsageConsumesCapacity() async throws {
        let setup = try makeSetup()
        defer { setup.fixture.removeFiles() }
        let deleted = try await setup.model.deleteUnlinkedBenefitAllowanceUsage(
            planID: setup.plan.id,
            expectedUsage: setup.usage
        )
        try await setup.model.recordAllowanceUsage(
            planID: setup.plan.id,
            expectedPolicyRevisionID: setup.policyID,
            amount: 95,
            categoryID: setup.fixture.food.id,
            occurredAt: setup.occurredAt,
            note: "Replacement use"
        )

        do {
            try await setup.model.restoreDeletedUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                deletedUsage: deleted,
                expectedPolicyRevisionID: setup.policyID
            )
            XCTFail("Undo must not exceed the current period capacity")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        XCTAssertEqual(setup.model.allowancePlans.first?.usages.count, 1)
        XCTAssertEqual(
            setup.model.allowancePlans.first?.usages.first?.amount.amount,
            95
        )
        await setup.fixture.store.close()
    }

    @MainActor
    func testUndoRejectsStalePolicyRevisionWithoutStoreChange() async throws {
        let setup = try makeSetup()
        defer { setup.fixture.removeFiles() }
        let deleted = try await setup.model.deleteUnlinkedBenefitAllowanceUsage(
            planID: setup.plan.id,
            expectedUsage: setup.usage
        )

        do {
            try await setup.model.restoreDeletedUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                deletedUsage: deleted,
                expectedPolicyRevisionID: UUID()
            )
            XCTFail("Undo must retain its exact governing policy revision")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        let stored = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.plan.id.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(setup.model.allowancePlans.first?.usages, [])
        XCTAssertEqual(stored?.usages, [])
        await setup.fixture.store.close()
    }

    @MainActor
    func testEditRollsBackMemoryAndWidgetDeferralWhenPersistenceFails()
        async throws {
        let setup = try makeSetup()
        defer { setup.fixture.removeFiles() }
        await setup.fixture.store.close()

        do {
            try await setup.model.updateUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                expectedUsage: setup.usage,
                expectedPolicyRevisionID: setup.policyID,
                amount: 30,
                categoryID: setup.fixture.food.id,
                occurredAt: setup.occurredAt,
                note: nil
            )
            XCTFail("A failed durable write must not publish the edit")
        } catch {
            // Persistence errors are deliberately not a stable UI contract.
        }
        XCTAssertEqual(setup.model.allowancePlans, [setup.plan])
        XCTAssertFalse(setup.model.widgetSnapshotRefreshWasDeferred)
    }

    @MainActor
    func testMutationFailsClosedForArchivedGrandfatheredAndLinkedEvidence()
        async throws {
        let setup = try makeSetup()
        defer { setup.fixture.removeFiles() }
        let archivedCandidate = try AllowancePlan(
            id: setup.plan.id,
            name: setup.plan.name,
            amount: setup.plan.amount,
            cadence: setup.plan.cadence,
            fundingMode: setup.plan.fundingMode,
            linkedAccountID: setup.plan.linkedAccountID,
            startsAt: setup.plan.startsAt,
            endsAt: setup.plan.endsAt,
            timeZoneIdentifier: setup.plan.timeZoneIdentifier,
            eligibleCategoryIDs: setup.plan.eligibleCategoryIDs,
            rolloverRule: setup.plan.rolloverRule,
            rolloverCap: setup.plan.rolloverCap,
            isArchived: true
        )
        setup.model.allowancePlans[0] = try setup.plan.applyingUpdate(
            archivedCandidate,
            effectiveAt: setup.now
        )
        do {
            _ = try await setup.model.deleteUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                expectedUsage: setup.usage
            )
            XCTFail("Archived allowance evidence must remain read-only")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        let grandfathered = try AllowancePlan(
            id: setup.plan.id,
            name: setup.plan.name,
            amount: setup.plan.amount,
            cadence: setup.plan.cadence,
            fundingMode: setup.plan.fundingMode,
            startsAt: setup.plan.startsAt,
            timeZoneIdentifier: setup.plan.timeZoneIdentifier,
            eligibleCategoryIDs: setup.plan.eligibleCategoryIDs,
            usages: [setup.usage],
            policyRevisions: setup.plan.policyRevisions,
            hasGrandfatheredActivity: true
        )
        setup.model.allowancePlans[0] = grandfathered
        do {
            _ = try await setup.model.deleteUnlinkedBenefitAllowanceUsage(
                planID: grandfathered.id,
                expectedUsage: setup.usage
            )
            XCTFail("Grandfathered allowance evidence must remain read-only")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        let linked = try AllowanceUsage(
            id: setup.usage.id,
            amount: setup.usage.amount,
            occurredAt: setup.usage.occurredAt,
            categoryID: setup.usage.categoryID,
            linkedJournalEntryID: UUID(),
            note: setup.usage.note,
            policyRevisionID: setup.usage.policyRevisionID
        )
        setup.model.allowancePlans[0] = setup.plan
        do {
            try await setup.model.restoreDeletedUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                deletedUsage: linked,
                expectedPolicyRevisionID: setup.policyID
            )
            XCTFail("Linked journal evidence cannot use standalone Undo")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        await setup.fixture.store.close()
    }

    @MainActor
    func testWidgetStaysStaleUntilAllowanceEditPublishesCoherentPlan()
        async throws {
        let gate = AllowanceMutationGate()
        let hooks = AppModelLifecycleHooks { checkpoint in
            guard checkpoint == .afterAllowanceUsageCommitBeforeApply else { return }
            await gate.suspend()
        }
        let suite = "MoneyUp-Allowance-Mutation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let setup = try makeSetup(hooks: hooks, widgetStore: widgetStore)
        defer { setup.fixture.removeFiles() }
        setup.model.refreshBudgetWidgetSnapshot()
        XCTAssertEqual(widgetStore.readInsights(now: setup.now)?.allowancePercentRemaining, 80)

        let mutation = Task { @MainActor in
            try await setup.model.updateUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                expectedUsage: setup.usage,
                expectedPolicyRevisionID: setup.policyID,
                amount: 40,
                categoryID: setup.fixture.food.id,
                occurredAt: setup.occurredAt,
                note: nil
            )
        }
        await gate.waitUntilSuspended()
        XCTAssertEqual(widgetStore.read(now: setup.now), .stale)
        XCTAssertNil(widgetStore.readInsights(now: setup.now))
        XCTAssertTrue(setup.model.widgetSnapshotRefreshWasDeferred)
        XCTAssertEqual(setup.model.allowancePlans.first?.usages.first?.amount.amount, 20)

        await gate.release()
        try await mutation.value
        XCTAssertFalse(setup.model.widgetSnapshotRefreshWasDeferred)
        XCTAssertEqual(widgetStore.readInsights(now: setup.now)?.allowancePercentRemaining, 60)
        XCTAssertEqual(setup.model.allowancePlans.first?.usages.first?.amount.amount, 40)
        await setup.fixture.store.close()
    }

    @MainActor
    func testWidgetStaysStaleUntilAllowanceDeletePublishesCoherentPlan()
        async throws {
        let gate = AllowanceMutationGate()
        let hooks = AppModelLifecycleHooks { checkpoint in
            guard checkpoint == .afterAllowanceUsageCommitBeforeApply else { return }
            await gate.suspend()
        }
        let suite = "MoneyUp-Allowance-Delete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let setup = try makeSetup(hooks: hooks, widgetStore: widgetStore)
        defer { setup.fixture.removeFiles() }
        setup.model.refreshBudgetWidgetSnapshot()

        let mutation = Task { @MainActor in
            try await setup.model.deleteUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                expectedUsage: setup.usage
            )
        }
        await gate.waitUntilSuspended()
        XCTAssertEqual(widgetStore.read(now: setup.now), .stale)
        XCTAssertNil(widgetStore.readInsights(now: setup.now))
        XCTAssertEqual(setup.model.allowancePlans.first?.usages, [setup.usage])

        await gate.release()
        let deleted = try await mutation.value
        XCTAssertEqual(deleted, setup.usage)
        XCTAssertEqual(setup.model.allowancePlans.first?.usages, [])
        XCTAssertEqual(widgetStore.readInsights(now: setup.now)?.allowancePercentRemaining, 100)
        await setup.fixture.store.close()
    }

    @MainActor
    func testAllowanceEditGenerationRaceDoesNotPublishStaleStoreResult()
        async throws {
        let gate = AllowanceMutationGate()
        let hooks = AppModelLifecycleHooks { checkpoint in
            guard checkpoint == .afterAllowanceUsageCommitBeforeApply else { return }
            await gate.suspend()
        }
        let setup = try makeSetup(hooks: hooks)
        defer { setup.fixture.removeFiles() }
        let mutation = Task { @MainActor in
            try await setup.model.updateUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                expectedUsage: setup.usage,
                expectedPolicyRevisionID: setup.policyID,
                amount: 30,
                categoryID: setup.fixture.food.id,
                occurredAt: setup.occurredAt,
                note: nil
            )
        }
        await gate.waitUntilSuspended()
        setup.model.storeGeneration &+= 1
        await gate.release()
        do {
            try await mutation.value
            XCTFail("A stale store generation must not publish")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        XCTAssertEqual(setup.model.allowancePlans, [setup.plan])
        XCTAssertFalse(setup.model.widgetSnapshotRefreshWasDeferred)
        await setup.fixture.store.close()
    }

    @MainActor
    func testDeferredWidgetPublishesBeforeRequestedLockClearsBook() async throws {
        let gate = AllowanceMutationGate()
        let hooks = AppModelLifecycleHooks { checkpoint in
            guard checkpoint == .afterAllowanceUsageCommitBeforeApply else { return }
            await gate.suspend()
        }
        let suite = "MoneyUp-Allowance-Lock-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let setup = try makeSetup(hooks: hooks, widgetStore: widgetStore)
        defer { setup.fixture.removeFiles() }
        setup.model.refreshBudgetWidgetSnapshot()

        let mutation = Task { @MainActor in
            try await setup.model.updateUnlinkedBenefitAllowanceUsage(
                planID: setup.plan.id,
                expectedUsage: setup.usage,
                expectedPolicyRevisionID: setup.policyID,
                amount: 30,
                categoryID: setup.fixture.food.id,
                occurredAt: setup.occurredAt,
                note: nil
            )
        }
        await gate.waitUntilSuspended()
        setup.model.lock()
        XCTAssertTrue(setup.model.lockAfterLifecycleMutation)
        await gate.release()
        try await mutation.value

        XCTAssertEqual(setup.model.state, .locked)
        XCTAssertEqual(widgetStore.readInsights(now: setup.now)?.allowancePercentRemaining, 70)
    }

    @MainActor
    func testJournalAndAllowanceSaveNeverPublishesMixedWidgetGeneration()
        async throws {
        let gate = AllowanceMutationGate()
        let hooks = AppModelLifecycleHooks { checkpoint in
            guard checkpoint == .afterAllowanceJournalProjectionBeforePlanApply
            else { return }
            await gate.suspend()
        }
        let suite = "MoneyUp-Allowance-Journal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let setup = try makeSetup(hooks: hooks, widgetStore: widgetStore)
        defer { setup.fixture.removeFiles() }
        setup.model.refreshBudgetWidgetSnapshot()
        let expense = try TransactionFactory.expense(
            amount: Money(10, currency: setup.fixture.sgd),
            paidFrom: setup.fixture.wallet.id,
            category: setup.fixture.food.id,
            occurredAt: setup.occurredAt.addingTimeInterval(60),
            payee: "Snack"
        )

        let mutation = Task { @MainActor in
            try await setup.model.save(
                expense,
                applyingAllowance: setup.plan.id
            )
        }
        await gate.waitUntilSuspended()
        XCTAssertTrue(setup.model.entries.contains { $0.id == expense.id })
        XCTAssertEqual(setup.model.allowancePlans.first?.usages.count, 1)
        XCTAssertTrue(setup.model.widgetSnapshotRefreshWasDeferred)
        XCTAssertEqual(widgetStore.read(now: setup.now), .stale)
        XCTAssertNil(widgetStore.readInsights(now: setup.now))

        await gate.release()
        let savedID = try await mutation.value
        XCTAssertEqual(savedID, expense.id)
        XCTAssertEqual(setup.model.allowancePlans.first?.usages.count, 2)
        XCTAssertFalse(setup.model.widgetSnapshotRefreshWasDeferred)
        XCTAssertEqual(widgetStore.readInsights(now: setup.now)?.allowancePercentRemaining, 70)
        await setup.fixture.store.close()
    }
}

private extension AllowanceUsageMutationTests {
    struct Setup {
        let fixture: AppModelFixture
        let model: AppModel
        let plan: AllowancePlan
        let usage: AllowanceUsage
        let policyID: UUID
        let occurredAt: Date
        let now: Date
    }

    @MainActor
    func makeSetup(
        hooks: AppModelLifecycleHooks = .none,
        widgetStore: BudgetWidgetSnapshotStore = BudgetWidgetSnapshotStore()
    ) throws -> Setup {
        let fixture = try AppModelFixture()
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "UTC"
        )
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 5,
            hour: 12
        ))!
        let startsAt = calendar.startOfDay(for: now)
        let base = try AllowancePlan(
            name: "Meals",
            amount: Money(100, currency: fixture.sgd),
            cadence: .daily,
            startsAt: startsAt,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id]
        )
        let policyID = base.policyRevisions[0].id
        let occurredAt = startsAt.addingTimeInterval(3_600)
        let usage = try AllowanceUsage(
            amount: Money(20, currency: fixture.sgd),
            occurredAt: occurredAt,
            categoryID: fixture.food.id,
            note: "Lunch",
            policyRevisionID: policyID
        )
        let plan = try base.addingUsage(usage)
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "UTC"
        )
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            allowancePlans: [plan],
            lifecycleHooks: hooks,
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { now }
        )
        return Setup(
            fixture: fixture,
            model: model,
            plan: plan,
            usage: usage,
            policyID: policyID,
            occurredAt: occurredAt,
            now: now
        )
    }
}

private actor AllowanceMutationGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        suspensionWaiters.forEach { $0.resume() }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
