import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class BudgetResilienceTests: XCTestCase {
    private let calendar = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "Asia/Singapore")

    private func date(_ month: Int = 9, day: Int = 6) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
    }

    private func timeline(_ nodes: [BudgetNode], now: Date, carry: [UUID: Money]? = nil) throws -> BudgetConfigurationTimeline {
        try BudgetConfigurationTimeline(currency: CurrencyCode("SGD"), revisions: [
            BudgetConfigurationRevision(effectiveMonth: XCTUnwrap(calendar.dateInterval(of: .month, for: now)?.start),
                                        nodes: nodes, openingCarry: carry)
        ])
    }

    @MainActor
    func testLegacyNameOnlyHistoryDifferenceLoadsBothScreensWithoutRewritingHistory() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let old = BudgetNode(id: fixture.food.id, name: "Earlier label", limit: try Money(100, currency: fixture.sgd))
        var current = old; current.name = "Renamed category"
        let history = try timeline([old], now: now)
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore",
                                  pinnedBudgetNodeIDs: [old.id])
        let entry = try fixture.expense(amount: 20, occurredAt: now)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food],
                               entries: [entry], budgetNodes: [current], budgetConfigurationTimeline: history)
        let model = fixture.model(retainsCompleteJournal: false, currentDate: { now })
        try await model.reloadPersistedBookForTesting()
        XCTAssertTrue(model.recoveryIssues.isEmpty)
        XCTAssertEqual(model.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 80)
        let plan = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
        XCTAssertEqual(plan.value?.summary?.remaining.amount, 80)
        let stored = try await fixture.store.fetch(BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID, from: .budgetConfigurationTimelines)
        XCTAssertEqual(stored, history)
        let storedEntry = try await fixture.store.fetch(JournalEntry.self, id: entry.id.uuidString, from: .journalEntries)
        XCTAssertEqual(storedEntry, entry)
        await fixture.store.close()
    }

    @MainActor
    func testFinancialHistoryMismatchStaysUnavailableWithSpecificCodeAndBackupStillWorks() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let old = BudgetNode(id: fixture.food.id, name: "Category", limit: try Money(100, currency: fixture.sgd))
        var current = old; current.limit = try Money(110, currency: fixture.sgd)
        let history = try timeline([old], now: now)
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food],
                               budgetNodes: [current], budgetConfigurationTimeline: history)
        let model = fixture.model(retainsCompleteJournal: false, currentDate: { now })
        try await model.reloadPersistedBookForTesting()
        guard case .unavailable(.budgetHistoryConfigurationMismatch) = model.budgetProgressThisMonthResult() else {
            return XCTFail("Different allocations must not be repaired by choosing one snapshot")
        }
        let plan = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
        guard case .unavailable(.budgetHistoryConfigurationMismatch) = plan else {
            return XCTFail("Plan must expose the same specific failure")
        }
        let archive = try await model.encryptedBackup(password: "Synthetic recovery password")
        let snapshot = try PortableArchive.open(archive, password: "Synthetic recovery password")
        XCTAssertTrue(snapshot.records.contains { $0.collection == RecordCollection.budgetConfigurationTimelines.rawValue })
        let stored = try await fixture.store.fetch(BudgetNode.self, id: old.id.uuidString, from: .budgetNodes)
        XCTAssertEqual(stored, current)
        XCTAssertEqual(model.budgetConfigurationTimeline, history)
        XCTAssertEqual(model.budgetConfigurationTimelineIssue?.rawValue, "DV-013")
        await fixture.store.close()
    }

    @MainActor
    func testTimeZoneChangePersistsProfileBudgetAnchorsAndExactCarryTogether() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name,
            limit: try Money(120, currency: fixture.sgd), purpose: .flexible,
            rolloverRule: .fullBalance, rolloverStartedAt: try date(8))
        let history = try timeline([node], now: now, carry: [node.id: Money(-30, currency: fixture.sgd)])
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore",
                                  pinnedBudgetNodeIDs: [node.id])
        let entry = try fixture.expense(amount: 20, occurredAt: now)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: [entry],
                               budgetNodes: [node], budgetConfigurationTimeline: history)
        let model = fixture.model(profile: profile, entries: [entry], budgetNodes: [node],
                                  budgetConfigurationTimeline: history, currentDate: { now })
        try await model.updateReportingTimeZone("GMT")
        XCTAssertEqual(model.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 70)
        XCTAssertEqual(model.budgetConfigurationTimeline?.revisions.first?.id, history.revisions.first?.id)
        XCTAssertEqual(model.budgetConfigurationTimeline?.revisions.first?.openingCarry, history.revisions.first?.openingCarry)
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let restored = fixture.model(store: reopened, retainsCompleteJournal: false, currentDate: { now })
        try await restored.reloadPersistedBookForTesting()
        XCTAssertEqual(restored.profile?.reportingTimeZoneIdentifier, "GMT")
        XCTAssertTrue(restored.recoveryIssues.isEmpty)
        XCTAssertEqual(restored.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 70)
        let plan = await restored.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
        XCTAssertEqual(plan.value?.summary?.remaining.amount, 70)
        let storedEntry = try await reopened.fetch(JournalEntry.self, id: entry.id.uuidString, from: .journalEntries)
        XCTAssertEqual(storedEntry, entry)
        await reopened.close()
    }

    @MainActor
    func testFailedTimeZoneWriteLeavesProfileNodesAndHistoryUnchanged() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        let history = try timeline([node], now: now)
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food],
                               budgetNodes: [node], budgetConfigurationTimeline: history)
        let model = fixture.model(profile: profile, budgetNodes: [node], budgetConfigurationTimeline: history, currentDate: { now })
        await fixture.store.close()
        do { try await model.updateReportingTimeZone("GMT"); XCTFail("Closed store must reject the complete write") }
        catch { XCTAssertTrue(error is PersistenceError) }
        XCTAssertEqual(model.profile, profile)
        XCTAssertEqual(model.budgetNodes, [node])
        XCTAssertEqual(model.budgetConfigurationTimeline, history)
        let reopened = try fixture.reopenStore()
        let saved = try await reopened.fetch(UserProfile.self, id: UserProfile.primaryRecordID, from: .profile)
        let stored = try await reopened.fetch(BudgetConfigurationTimeline.self, id: BudgetConfigurationTimeline.primaryRecordID,
                                              from: .budgetConfigurationTimelines)
        XCTAssertEqual(saved, profile)
        XCTAssertEqual(stored, history)
        await reopened.close()
    }

    @MainActor
    func testPinAndDisplayChangesKeepLazyFinancialCachesAvailable() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore",
                                  pinnedBudgetNodeIDs: [node.id])
        let entry = try fixture.expense(amount: 20, occurredAt: now)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: [entry], budgetNodes: [node])
        let model = fixture.model(retainsCompleteJournal: false, currentDate: { now })
        try await model.reloadPersistedBookForTesting()
        XCTAssertEqual(model.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 80)
        let revision = model.journalProjectionRevision
        let treeBuilds = model.budgetTreeCacheBuildCount
        for _ in 0..<3 {
            try await model.setBudgetNodePinned(node.id, isPinned: false)
            try await model.setBudgetNodePinned(node.id, isPinned: true)
        }
        model.changeDisplayPreferences { $0.showsDailyGuidance = false }
        await model.displayPreferenceWriteTask?.value
        XCTAssertEqual(model.journalProjectionRevision, revision)
        XCTAssertEqual(model.budgetTreeCacheBuildCount, treeBuilds)
        XCTAssertNil(model.journalDerivedRefreshTask)
        XCTAssertEqual(model.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 80)
        XCTAssertNotNil(model.reportResult(for: .thisMonth).value)
        await fixture.store.close()
    }

    @MainActor
    func testCancelledRecoveryReadDoesNotDiscardDraftOrQuarantineHistory() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let draft = QuickLogDraft(kind: .expense, amountText: "20", destinationAmountText: "",
            accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: fixture.food.id,
            occurredAt: Date(), dateWasEdited: false, payee: "Keep", note: "Keep draft", smartText: "")
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], quickLogDraft: draft)
        let model = fixture.model(quickLogDraft: draft)
        for readsDraft in [true, false] {
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                if readsDraft { try await model.loadQuickLogDraft(from: fixture.store, mode: .recovering) }
                else { try await model.loadBudgetConfigurationTimeline(from: fixture.store) }
            }
            do { try await task.value; XCTFail("Cancelled read must stop") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(model.quickLogDraft, draft)
        XCTAssertFalse(model.budgetConfigurationTimelineInvalid)
        XCTAssertTrue(model.recoveryIssues.isEmpty)
        let stored = try await fixture.store.fetch(QuickLogDraft.self, id: QuickLogDraft.primaryRecordID, from: .quickLogDrafts)
        XCTAssertEqual(stored, draft)
        await fixture.store.close()
    }

    @MainActor
    func testPlanReportsPendingDuringMutationThenLoadsCommittedState() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], budgetNodes: [node])
        let model = fixture.model(profile: profile, budgetNodes: [node], currentDate: { now })
        try model.beginLifecycleMutation()
        let pending = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
        model.endLifecycleMutation()
        guard case .unavailable(.budgetRefreshPending) = pending else { return XCTFail("Saving is not a calculation error") }
        let ready = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
        XCTAssertEqual(ready.value?.summary?.limit.amount, 100)
        await fixture.store.close()
    }

    @MainActor
    func testBudgetProjectionFailureDoesNotDisableBalancesOrSpendingReports() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date()
        let old = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        var current = old; current.limit = try Money(110, currency: fixture.sgd)
        let history = try timeline([old], now: now)
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
        let entry = try fixture.expense(amount: 20, occurredAt: now)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: [entry],
                               budgetNodes: [current], budgetConfigurationTimeline: history)
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food],
            budgetNodes: [current], retainsCompleteJournal: false, budgetConfigurationTimeline: history,
            currentDate: { now })
        try await model.refreshJournalDerivedState()
        XCTAssertEqual(model.budgetProjectionIssue, .budgetHistoryConfigurationMismatch)
        XCTAssertEqual(model.reportResult(for: .thisMonth).value?.baseFlow.expense.amount, 20)
        XCTAssertEqual(model.displayBalanceResult(for: fixture.wallet).value?.amount, -20)
        XCTAssertNil(model.journalDerivedRefreshIssue)
        XCTAssertTrue(model.journalRecentEntriesAreCurrent)
        guard case .unavailable(.budgetHistoryConfigurationMismatch) = model.budgetProgressThisMonthResult() else {
            return XCTFail("Valid ledger publication must not bypass budget validation")
        }
        await fixture.store.close()
    }

    @MainActor
    func testFailedRefreshStopsAutomaticRetryAndExplicitRetryMakesOneNewAttempt() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(retainsCompleteJournal: false)
        await fixture.store.close()
        model.scheduleJournalDerivedRefresh()
        let first = try XCTUnwrap(model.journalDerivedRefreshTask)
        await first.value
        XCTAssertEqual(model.journalDerivedRefreshIssue, .budgetReadFailed)
        XCTAssertNil(model.journalDerivedRefreshTask)
        for _ in 0..<3 {
            guard case .unavailable(.budgetReadFailed) = model.reportResult(for: .thisMonth) else {
                return XCTFail("A failed read must not remain a loading or unlock state")
            }
            XCTAssertNil(model.journalDerivedRefreshTask)
        }
        model.retryUnavailableJournalProjection()
        let retry = try XCTUnwrap(model.journalDerivedRefreshTask)
        await retry.value
        XCTAssertEqual(model.journalDerivedRefreshIssue, .budgetReadFailed)
        XCTAssertNil(model.journalDerivedRefreshTask)
        XCTAssertFalse(model.journalDerivedRefreshWasDeferred)
    }

    func testBudgetDiagnosticsDistinguishFailuresWithoutAssociatedFinancialPayloads() throws {
        let cases: [(Error, DerivedValueIssue)] = [
            (BudgetReportingConfigurationError.currentConfigurationMismatch, .budgetHistoryConfigurationMismatch),
            (BudgetReportingConfigurationError.invalidMonthBoundary, .budgetHistoryPeriodMismatch),
            (BudgetReportingConfigurationError.currencyMismatch, .budgetHistoryCurrencyMismatch),
            (BudgetTreeError.missingParent(nodeID: UUID(), parentID: UUID()), .budgetHierarchyInvalid),
            (DecimalCalculationError.overflow, .budgetArithmeticFailed),
            (PersistenceError.databaseClosed, .budgetReadFailed),
            (CancellationError(), .budgetRefreshPending)
        ]
        for (error, expected) in cases {
            let issue = DerivedValueIssue.budgetFailure(error, operation: "test-budget-read")
            XCTAssertEqual(issue, expected)
            XCTAssertEqual(issue.rawValue.count, 6)
        }
    }
}
