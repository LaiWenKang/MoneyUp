@testable import MoneyUp
import Foundation
import MoneyUpCore
import XCTest

final class RestrictedAllowanceAsOfProjectionTests: XCTestCase {
    func testUntouchedManagedBalanceDoesNotPersistAfterClockBoundary() {
        XCTAssertFalse(ManagedAccountBalanceEditPolicy.shouldPersist(
            initial: 100,
            edited: 100
        ))
        XCTAssertTrue(ManagedAccountBalanceEditPolicy.shouldPersist(
            initial: 100,
            edited: 120
        ))
        XCTAssertTrue(ManagedAccountBalanceEditPolicy.shouldPersist(
            initial: nil,
            edited: 120
        ))
    }

    @MainActor
    func testFutureTopUpDoesNotIncreaseCurrentAllowanceWidgetOrAssets()
        async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let context = try makeContext(fixture: fixture)
        let clock = RestrictedAllowanceTestClock(context.now)
        let futureTopUp = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(50, currency: fixture.sgd),
            accountID: context.restricted.id,
            equityAccountID: context.equity.id,
            accountIsLiability: false,
            occurredAt: context.future
        )
        let plan = try makePlan(
            fixture: fixture,
            accountID: context.restricted.id,
            startsAt: context.start
        )
        let model = try await compactModel(
            fixture: fixture,
            context: context,
            entries: [futureTopUp],
            plan: plan,
            clock: clock
        )

        XCTAssertEqual(
            model.displayBalanceResult(for: context.restricted).value?.amount,
            50,
            "The ending-balance cache intentionally includes future rows"
        )
        XCTAssertEqual(
            model.allowancePresentation(plan, asOf: context.now)
                .remaining.value?.amount,
            0
        )
        XCTAssertEqual(
            model.widgetInsights(asOf: context.now)?.allowancePercentRemaining,
            0
        )
        XCTAssertEqual(
            model.restrictedAllowanceValueByCurrencyResult(asOf: context.now)
                .value?.first?.amount,
            0
        )
        XCTAssertEqual(
            model.accountBalanceResultForPresentation(
                for: context.restricted,
                asOf: context.now
            ).value?.amount,
            0
        )
        XCTAssertEqual(
            model.widgetInsights(asOf: context.now)?.validUntil,
            context.future
        )

        for outsideProjection in [
            context.now.addingTimeInterval(-60),
            context.future.addingTimeInterval(60)
        ] {
            guard case .unavailable(.appNotReady) = model.allowancePresentation(
                plan,
                asOf: outsideProjection
            ).remaining else {
                return XCTFail("Compact presentation must fail closed out of range")
            }
        }
        XCTAssertNil(
            model.journalDerivedRefreshTask,
            "A current-time refresh cannot satisfy arbitrary as-of presentation"
        )
        let futureSpendable = try await model.prepaidAllowanceSpendable(
            planID: plan.id,
            asOf: context.future.addingTimeInterval(60)
        )
        XCTAssertEqual(
            futureSpendable.amount,
            50,
            "Quick Log keeps exact asynchronous transaction-time authority"
        )

        let priorLogicalBookRevision = model.logicalBookRevision
        model.isBookReplacementInProgress = true
        model.isWorking = true
        model.isLifecycleMutationInProgress = true
        model.finishBookReplacementMutation()
        XCTAssertEqual(model.logicalBookRevision, priorLogicalBookRevision &+ 1)
        XCTAssertEqual(
            model.allowancePresentation(plan, asOf: context.now)
                .remaining.value?.amount,
            0,
            "The restore finish path must retain its freshly rebuilt projection"
        )
        await model.waitForPendingJournalDerivedRefresh()
        await fixture.store.close()
    }

    @MainActor
    func testFutureDebitDoesNotReduceCurrentAllowanceWidgetOrAssets()
        async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let context = try makeContext(fixture: fixture)
        let clock = RestrictedAllowanceTestClock(context.now)
        let opening = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(100, currency: fixture.sgd),
            accountID: context.restricted.id,
            equityAccountID: context.equity.id,
            accountIsLiability: false,
            occurredAt: context.now.addingTimeInterval(-3_600)
        )
        let futureExpense = try TransactionFactory.expense(
            amount: Money(80, currency: fixture.sgd),
            paidFrom: context.restricted.id,
            category: fixture.food.id,
            occurredAt: context.future
        )
        var plan = try makePlan(
            fixture: fixture,
            accountID: context.restricted.id,
            startsAt: context.start
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: Money(80, currency: fixture.sgd),
            occurredAt: context.future,
            categoryID: fixture.food.id,
            linkedJournalEntryID: futureExpense.id,
            policyRevisionID: plan.policy(at: context.future)?.id
        ))
        let model = try await compactModel(
            fixture: fixture,
            context: context,
            entries: [opening, futureExpense],
            plan: plan,
            clock: clock
        )

        XCTAssertEqual(
            model.displayBalanceResult(for: context.restricted).value?.amount,
            20,
            "The ending-balance cache intentionally includes future rows"
        )
        XCTAssertEqual(
            model.allowancePresentation(plan, asOf: context.now)
                .remaining.value?.amount,
            100
        )
        XCTAssertEqual(
            model.widgetInsights(asOf: context.now)?.allowancePercentRemaining,
            100
        )
        XCTAssertEqual(
            model.restrictedAllowanceValueByCurrencyResult(asOf: context.now)
                .value?.first?.amount,
            100
        )
        XCTAssertEqual(
            model.accountBalanceResultForPresentation(
                for: context.restricted,
                asOf: context.now
            ).value?.amount,
            100
        )

        clock.set(context.future)
        model.refreshRestrictedAllowanceProjectionIfNeeded(asOf: context.future)
        guard case .unavailable(.appNotReady) =
            model.allowancePresentation(plan, asOf: context.future).remaining else {
            return XCTFail("The pre-boundary projection must fail closed at expiry")
        }
        await model.waitForPendingJournalDerivedRefresh()
        XCTAssertEqual(
            model.allowancePresentation(plan, asOf: context.future)
                .remaining.value?.amount,
            20
        )
        XCTAssertEqual(
            model.restrictedAllowanceValueByCurrencyResult(asOf: context.future)
                .value?.first?.amount,
            20
        )
        XCTAssertEqual(
            model.accountBalanceResultForPresentation(
                for: context.restricted,
                asOf: context.future
            ).value?.amount,
            20
        )
        await fixture.store.close()
    }

    @MainActor
    func testRestrictedBalanceAdjustmentUsesCurrentAsOfBalanceNotFutureEndingBalance()
        async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let context = try makeContext(fixture: fixture)
        let clock = RestrictedAllowanceTestClock(context.now)
        let opening = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(100, currency: fixture.sgd),
            accountID: context.restricted.id,
            equityAccountID: context.equity.id,
            accountIsLiability: false,
            occurredAt: context.now.addingTimeInterval(-3_600)
        )
        let futureTopUp = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(50, currency: fixture.sgd),
            accountID: context.restricted.id,
            equityAccountID: context.equity.id,
            accountIsLiability: false,
            occurredAt: context.future
        )
        let plan = try makePlan(
            fixture: fixture,
            accountID: context.restricted.id,
            startsAt: context.start
        )
        let model = try await compactModel(
            fixture: fixture,
            context: context,
            entries: [opening, futureTopUp],
            plan: plan,
            clock: clock
        )

        XCTAssertEqual(
            model.accountBalanceResultForPresentation(
                for: context.restricted,
                asOf: context.now
            ).value?.amount,
            100
        )
        try await model.setAccountBalance(
            accountID: context.restricted.id,
            displayBalance: 120
        )

        XCTAssertEqual(
            model.accountBalanceResultForPresentation(
                for: context.restricted,
                asOf: context.now
            ).value?.amount,
            120
        )
        XCTAssertEqual(
            model.displayBalanceResult(for: context.restricted).value?.amount,
            170
        )
        let stored = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        let currentAdjustment = try XCTUnwrap(stored.first {
            $0.id != opening.id && $0.id != futureTopUp.id
        })
        XCTAssertEqual(currentAdjustment.occurredAt, context.now)
        XCTAssertEqual(
            currentAdjustment.postings.first {
                $0.accountID == context.restricted.id
            }?.money.amount,
            20
        )
        await fixture.store.close()
    }

    private struct Context {
        let start: Date
        let now: Date
        let future: Date
        let restricted: LedgerAccount
        let equity: LedgerAccount
    }

    private func makeContext(fixture: AppModelFixture) throws -> Context {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 1)
        ))
        let now = try XCTUnwrap(calendar.date(
            from: DateComponents(
                year: 2026,
                month: 9,
                day: 5,
                hour: 12
            )
        ))
        let future = try XCTUnwrap(calendar.date(
            from: DateComponents(
                year: 2026,
                month: 9,
                day: 5,
                hour: 18
            )
        ))
        return Context(
            start: start,
            now: now,
            future: future,
            restricted: LedgerAccount(
                name: "Meal card",
                kind: .asset,
                currency: fixture.sgd,
                accountType: .restrictedAllowance
            ),
            equity: LedgerAccount(
                name: "Opening balances",
                kind: .equity,
                systemRole: .openingBalances
            )
        )
    }

    private func makePlan(
        fixture: AppModelFixture,
        accountID: UUID,
        startsAt: Date
    ) throws -> AllowancePlan {
        try AllowancePlan(
            name: "Meals",
            amount: Money(100, currency: fixture.sgd),
            cadence: .monthly,
            fundingMode: .prepaidAsset,
            linkedAccountID: accountID,
            startsAt: startsAt,
            timeZoneIdentifier: "UTC"
        )
    }

    @MainActor
    private func compactModel(
        fixture: AppModelFixture,
        context: Context,
        entries: [JournalEntry],
        plan: AllowancePlan,
        clock: RestrictedAllowanceTestClock
    ) async throws -> AppModel {
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "UTC"
        )
        let accounts = [
            context.restricted,
            context.equity,
            fixture.food
        ]
        try await fixture.seed(
            profile: profile,
            accounts: accounts,
            entries: entries,
            allowancePlans: [plan]
        )
        let model = fixture.model(
            profile: profile,
            accounts: accounts,
            allowancePlans: [plan],
            retainsCompleteJournal: false,
            currentDate: { clock.value() }
        )
        await model.waitForPendingJournalDerivedRefresh()
        return model
    }
}

private final class RestrictedAllowanceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) {
        self.instant = instant
    }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func set(_ instant: Date) {
        lock.lock()
        self.instant = instant
        lock.unlock()
    }
}
