import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class BudgetPeriodRecoveryTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: zone)
    }

    private func date(_ month: Int = 9, day: Int = 1, zone: String = "Asia/Singapore") throws -> Date {
        try XCTUnwrap(calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day)))
    }

    @MainActor
    func testUpgradeRecoversTodayAndPlanAndPreservesOriginalsTransactionsAndDraftAcrossReopen() async throws {
        for (oldZone, newZone) in [("Asia/Singapore", "GMT"), ("GMT", "Asia/Singapore")] {
            let fixture = try AppModelFixture()
            defer { fixture.removeFiles() }
            let now = try date(day: 6)
            let node = BudgetNode(id: fixture.food.id, name: fixture.food.name,
                limit: try Money(120, currency: fixture.sgd), rolloverRule: .fullBalance,
                rolloverStartedAt: try date(8, zone: oldZone),
                monthlyAllocations: [try MonthlyBudgetAllocation(month: BudgetMonth(year: 2026, month: 9),
                    currency: fixture.usd, limit: Money(30, currency: fixture.usd))])
            let history = try BudgetConfigurationTimeline(currency: fixture.sgd, revisions: [
                BudgetConfigurationRevision(effectiveMonth: date(8, zone: oldZone), nodes: [node]),
                BudgetConfigurationRevision(effectiveMonth: date(zone: oldZone), nodes: [node],
                    openingCarry: [node.id: Money(-30, currency: fixture.sgd)])
            ])
            let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: newZone,
                pinnedBudgetNodeIDs: [node.id])
            let entry = try fixture.expense(amount: 20, occurredAt: now)
            let draft = QuickLogDraft(kind: .expense, amountText: "12.34", destinationAmountText: "",
                accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: fixture.food.id,
                occurredAt: now, dateWasEdited: true, payee: "Keep draft", note: "Keep note", smartText: "")
            try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: [entry],
                budgetNodes: [node], budgetConfigurationTimeline: history, quickLogDraft: draft)
            let recordsBefore = try await fixture.store.snapshot().records
            let model = fixture.model(retainsCompleteJournal: false, currentDate: { now })
            try await model.reloadPersistedBookForTesting()
            XCTAssertTrue(model.recoveryIssues.isEmpty)
            XCTAssertNil(model.budgetConfigurationTimelineIssue)
            XCTAssertEqual(model.profile, profile)
            XCTAssertEqual(model.quickLogDraft, draft)
            XCTAssertEqual(model.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 70)
            let plan = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
            XCTAssertEqual(plan.value?.summary?.remaining.amount, 70)
            let expectedOriginal = BudgetPeriodRecoveryOriginal(nodes: [node], timeline: history,
                reportingTimeZoneIdentifier: newZone)
            let storedOriginal = try await fixture.store.fetch(BudgetPeriodRecoveryOriginal.self,
                id: BudgetPeriodRecoveryOriginal.recordID, from: .budgetConfigurationTimelines)
            XCTAssertEqual(storedOriginal, expectedOriginal)
            let storedEntry = try await fixture.store.fetch(JournalEntry.self, id: entry.id.uuidString, from: .journalEntries)
            XCTAssertEqual(storedEntry, entry)
            let recordsAfter = try await fixture.store.snapshot().records
            for record in recordsBefore where record.collection != RecordCollection.budgetNodes.rawValue
                && record.collection != RecordCollection.budgetConfigurationTimelines.rawValue {
                XCTAssertTrue(recordsAfter.contains(record), "Non-budget records must remain byte-for-byte unchanged")
            }

            let archive = try await model.encryptedBackup(password: "Synthetic recovery password")
            let snapshot = try PortableArchive.open(archive, password: "Synthetic recovery password")
            try RestoreCandidateValidator.validateSnapshotIdentities(snapshot)
            XCTAssertTrue(snapshot.records.contains { $0.recordID == BudgetPeriodRecoveryOriginal.recordID })
            let repaired = model.budgetConfigurationTimeline
            await fixture.store.close()
            let reopened = try fixture.reopenStore()
            let restored = fixture.model(store: reopened, retainsCompleteJournal: false, currentDate: { now })
            try await restored.reloadPersistedBookForTesting()
            XCTAssertTrue(restored.recoveryIssues.isEmpty)
            XCTAssertEqual(restored.budgetConfigurationTimeline, repaired)
            XCTAssertEqual(restored.quickLogDraft, draft)
            XCTAssertEqual(restored.pinnedBudgetSummariesResult().value?.first?.remaining?.amount, 70)
            let reopenedOriginal = try await reopened.fetch(BudgetPeriodRecoveryOriginal.self,
                id: BudgetPeriodRecoveryOriginal.recordID, from: .budgetConfigurationTimelines)
            XCTAssertEqual(reopenedOriginal, expectedOriginal)
            try await restored.restoreEncryptedBackup(archive, password: "Synthetic recovery password")
            XCTAssertTrue(restored.recoveryIssues.isEmpty)
            XCTAssertEqual(restored.quickLogDraft, draft)
            let restoredOriginal = try await reopened.fetch(BudgetPeriodRecoveryOriginal.self,
                id: BudgetPeriodRecoveryOriginal.recordID, from: .budgetConfigurationTimelines)
            XCTAssertEqual(restoredOriginal, expectedOriginal)
            await reopened.close()
        }
    }

    @MainActor
    func testMalformedDatesStayQuarantinedWithoutWritingAReplacementOrOriginal() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date(day: 20)
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        let history = try BudgetConfigurationTimeline(currency: fixture.sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(day: 15), nodes: [node])
        ])
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food],
            budgetNodes: [node], budgetConfigurationTimeline: history)
        let model = fixture.model(currentDate: { now })
        try await model.reloadPersistedBookForTesting()
        XCTAssertEqual(model.budgetConfigurationTimelineIssue, .budgetHistoryPeriodMismatch)
        XCTAssertEqual(model.budgetConfigurationTimeline, history)
        let stored = try await fixture.store.fetch(BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID, from: .budgetConfigurationTimelines)
        let original = try await fixture.store.fetch(BudgetPeriodRecoveryOriginal.self,
            id: BudgetPeriodRecoveryOriginal.recordID, from: .budgetConfigurationTimelines)
        XCTAssertEqual(stored, history)
        XCTAssertNil(original)
        await fixture.store.close()
    }

    @MainActor
    func testRollbackRecoveryDoesNotRewriteOriginalSnapshot() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date(day: 6)
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        let history = try BudgetConfigurationTimeline(currency: fixture.sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(), nodes: [node])
        ])
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food],
            budgetNodes: [node], budgetConfigurationTimeline: history)
        let model = fixture.model(currentDate: { now })
        try await model.load(from: fixture.store, mode: .rollbackRecovery)
        XCTAssertEqual(model.budgetConfigurationTimelineIssue, .budgetHistoryPeriodMismatch)
        let stored = try await fixture.store.fetch(BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID, from: .budgetConfigurationTimelines)
        let original = try await fixture.store.fetch(BudgetPeriodRecoveryOriginal.self,
            id: BudgetPeriodRecoveryOriginal.recordID, from: .budgetConfigurationTimelines)
        XCTAssertEqual(stored, history)
        XCTAssertNil(original)
        await fixture.store.close()
    }

    @MainActor
    func testFailedRecoveryAndCancellationLeaveAllPublishedStateUnchanged() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date(day: 6)
        let node = BudgetNode(id: fixture.food.id, name: fixture.food.name, limit: try Money(100, currency: fixture.sgd))
        let history = try BudgetConfigurationTimeline(currency: fixture.sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(), nodes: [node])
        ])
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food],
            budgetNodes: [node], budgetConfigurationTimeline: history)
        let model = fixture.model(profile: profile, budgetNodes: [node], budgetConfigurationTimeline: history,
            currentDate: { now })
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await model.recoverLegacyBudgetPeriods(in: fixture.store)
        }
        do { try await cancelled.value; XCTFail("Cancellation must stop recovery") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fixture.store.close()
        do { try await model.recoverLegacyBudgetPeriods(in: fixture.store); XCTFail("Closed store must reject recovery") }
        catch { XCTAssertTrue(error is PersistenceError) }
        XCTAssertEqual(model.profile, profile)
        XCTAssertEqual(model.budgetNodes, [node])
        XCTAssertEqual(model.budgetConfigurationTimeline, history)
    }

    @MainActor
    func testGiftAndOtherCategoryEditsWorkAfterPeriodRecoveryWithoutDeletingUserData() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try date(day: 6)
        let shopping = LedgerAccount(name: "Shopping", kind: .expense, parentID: fixture.food.id)
        let gift = LedgerAccount(name: "Gift", kind: .expense, parentID: shopping.id)
        let other = LedgerAccount(name: "Others", kind: .expense)
        let categories = [fixture.food, shopping, gift, other]
        let nodes = categories.map { BudgetNode(id: $0.id, parentID: $0.parentID,
            name: $0.name, allocationMode: .automatic) }
        let history = try BudgetConfigurationTimeline(currency: fixture.sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(), nodes: nodes)
        ])
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "GMT")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet] + categories,
            budgetNodes: nodes, budgetConfigurationTimeline: history)
        let model = fixture.model(currentDate: { now })
        try await model.reloadPersistedBookForTesting()
        XCTAssertTrue(model.recoveryIssues.isEmpty)
        XCTAssertEqual(model.accountsByID[gift.id], gift)
        XCTAssertEqual(model.accountsByID[other.id], other)
        try await model.updateCategoryMetadata(categoryID: gift.id, name: "Gifts", amount: nil,
            purpose: .unclassified, rolloverRule: .none)
        try await model.setMonthlyBudget(categoryID: gift.id, date: now, currency: fixture.sgd,
            amount: 100, mode: .automatic, purpose: .flexible)
        let added = try await model.addCategory(name: "Another category", kind: .expense, parentID: shopping.id)
        XCTAssertEqual(model.accountsByID[added]?.parentID, shopping.id)
        let plan = await model.monthlyBudgetPresentation(asOf: now, currency: fixture.sgd)
        XCTAssertEqual(plan.value?.summary?.limit.amount, 100)
        XCTAssertEqual(model.accountsByID[other.id], other)
        await fixture.store.close()
    }

    @MainActor
    func testBackupReviewPreservesExistingDraftAndQueuedCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(kind: .expense, amountText: "20")
        let inbox = InMemoryLockedCaptureStore(captures: [capture])
        let draft = QuickLogDraft(kind: .income, amountText: "90", destinationAmountText: "",
            accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: nil,
            occurredAt: Date(), dateWasEdited: false, payee: "Keep income", note: "Keep", smartText: "")
        let model = fixture.model(quickLogDraft: draft, lockedCaptureStore: inbox)
        try await model.reviewPendingLockedCapturesForBackup()
        XCTAssertEqual(model.quickLogDraft, draft)
        XCTAssertEqual(model.requestedQuickLogMode, .income)
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)
        let remaining = try await inbox.all()
        XCTAssertEqual(remaining, [capture])
        await fixture.store.close()
    }

    @MainActor
    func testReviewingLastCaptureUnblocksBackupAndIncludesItsUncommittedDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(kind: .expense, amountText: "20", payee: "Pending")
        let inbox = InMemoryLockedCaptureStore(captures: [capture])
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food])
        let model = fixture.model(profile: profile, lockedCaptureStore: inbox)
        model.pendingLockedCaptureCount = 1
        do { _ = try await model.encryptedBackup(password: "Synthetic recovery password"); XCTFail("Pending inbox must remain protected") }
        catch AppModelError.pendingLockedCaptures {}
        try await model.reviewPendingLockedCapturesForBackup()
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, capture.id)
        XCTAssertEqual(model.requestedQuickLogMode, .expense)
        XCTAssertEqual(model.requestedQuickLogRequest?.id, 1, "Review must publish only one navigation request")
        let archive = try await model.encryptedBackup(password: "Synthetic recovery password")
        let snapshot = try PortableArchive.open(archive, password: "Synthetic recovery password")
        let record = try XCTUnwrap(snapshot.records.first { $0.collection == RecordCollection.quickLogDrafts.rawValue })
        let backedUpDraft = try JSONDecoder().decode(QuickLogDraft.self, from: record.payload)
        XCTAssertEqual(backedUpDraft.sourceCaptureID, capture.id)
        XCTAssertEqual(backedUpDraft.amountText, "20")
        XCTAssertEqual(backedUpDraft.payee, "Pending")
        await fixture.store.close()
    }
}
