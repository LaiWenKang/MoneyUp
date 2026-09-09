import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

enum BatchReviewTestSupport {
    static let now = Date(timeIntervalSince1970: 1_788_933_600)

    @MainActor
    static func start(_ fixture: AppModelFixture, hooks: AppModelLifecycleHooks = .none) async throws -> AppModel {
        let original = QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "",
            accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: fixture.food.id,
            occurredAt: now, dateWasEdited: false, payee: "", note: "", smartText:
                "lunch SGD12.50 Wallet Food yesterday; with Sam\nrefund SGD3 Wallet Food; returned coffee\ntransfer SGD10 from Wallet to USD Cash received USD7.50; savings")
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food]
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd), accounts: accounts, quickLogDraft: original)
        let model = fixture.model(accounts: accounts, quickLogDraft: original, lifecycleHooks: hooks, currentDate: { now })
        let prepared = try QuickLogBatchPreparation.prepare(original, accounts: accounts, now: now,
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_SG"), dayFirst: true)
        try await model.beginQuickLogBatch(prepared, replacing: original)
        return model
    }

    @MainActor
    static func saveCurrent(_ model: AppModel) async throws -> UUID? {
        let draft = try XCTUnwrap(model.quickLogDraft)
        let token = try XCTUnwrap(draft.batch?.token)
        let amount = try XCTUnwrap(decimalAmount(from: draft.amountText))
        let account = try XCTUnwrap(draft.accountID)
        switch draft.kind {
        case .expense:
            return try await model.logExpense(amount: amount, accountID: account, categoryID: XCTUnwrap(draft.categoryID),
                occurredAt: draft.occurredAt, payee: draft.payee, note: draft.note, batchToken: token)
        case .refund:
            return try await model.logRefund(amount: amount, accountID: account, categoryID: XCTUnwrap(draft.categoryID),
                occurredAt: draft.occurredAt, payee: draft.payee, note: draft.note, batchToken: token)
        case .income:
            return try await model.logIncome(amount: amount, accountID: account, categoryID: XCTUnwrap(draft.categoryID),
                occurredAt: draft.occurredAt, payee: draft.payee, note: draft.note, batchToken: token)
        case .transfer:
            return try await model.logTransfer(amount: amount, destinationAmount: decimalAmount(from: draft.destinationAmountText),
                sourceAccountID: account, destinationAccountID: XCTUnwrap(draft.destinationAccountID),
                occurredAt: draft.occurredAt, payee: draft.payee, note: draft.note, batchToken: token)
        }
    }
}

final class QuickLogBatchTests: XCTestCase {
    @MainActor
    func testSaveAdvancesExactlyOneItemAndRejectsStaleSaveAndFormCallbacks() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = try await BatchReviewTestSupport.start(fixture)
        let old = try XCTUnwrap(model.quickLogDraft)
        XCTAssertEqual(old.note, "with Sam")
        _ = try await BatchReviewTestSupport.saveCurrent(model)
        let next = try XCTUnwrap(model.quickLogDraft)
        XCTAssertEqual(next.batch?.items.count, 2)
        XCTAssertEqual(next.kind, .refund)
        XCTAssertEqual(next.occurredAt, BatchReviewTestSupport.now)
        XCTAssertEqual(next.note, "returned coffee")
        do {
            _ = try await model.logExpense(amount: 12.5, accountID: fixture.wallet.id, categoryID: fixture.food.id,
                occurredAt: old.occurredAt, payee: old.payee, note: old.note, batchToken: old.batch?.token)
            XCTFail("A consumed token must not save again")
        } catch { }
        model.updateQuickLogDraft(old)
        XCTAssertEqual(model.quickLogDraft, next)
        _ = try await BatchReviewTestSupport.saveCurrent(model)
        XCTAssertEqual(model.quickLogDraft?.kind, .transfer)
        _ = try await BatchReviewTestSupport.saveCurrent(model)
        XCTAssertNil(model.quickLogDraft)
        let stored = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(stored.count, 3)
        let balances = try FinanceCalculator.balancesByAccount(entries: stored)
        XCTAssertEqual(balances[fixture.wallet.id]?[fixture.sgd]?.amount, Decimal(string: "-19.50"))
        XCTAssertEqual(balances[fixture.usAccount.id]?[fixture.usd]?.amount, Decimal(string: "7.50"))
        await fixture.store.close()
    }

    @MainActor
    func testStoreReopenBetweenCommitAndPublicationSeesEntryAndNextDraftTogether() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = BatchCommitGate()
        let model = try await BatchReviewTestSupport.start(fixture, hooks: AppModelLifecycleHooks { point in
            if point == .afterJournalCommitBeforeProjectionRefresh { await gate.pause() }
        })
        let first = try XCTUnwrap(model.quickLogDraft)
        let save = Task { try await BatchReviewTestSupport.saveCurrent(model) }
        await gate.waitUntilReached()
        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetch(QuickLogDraft.self, id: "current", from: .quickLogDrafts)
        let entries = try await reopened.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(persisted?.batch?.items.count, 2)
        XCTAssertNotEqual(persisted?.batch?.selectedID, first.batch?.selectedID)
        await reopened.close()
        await gate.release()
        _ = try await save.value
        XCTAssertEqual(model.quickLogDraft, persisted)
        await fixture.store.close()
    }

    @MainActor
    func testNavigationAndItemLocalClearRecoveryCannotResurrectASavedSibling() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = try await BatchReviewTestSupport.start(fixture)
        var first = try XCTUnwrap(model.quickLogDraft)
        let firstID = try XCTUnwrap(first.batch?.selectedID)
        let secondID = try XCTUnwrap(first.batch?.items[1].id)
        first.amountText = "13.70"
        first.smartState.edited(.amount)
        model.updateQuickLogDraft(first)
        try await model.clearQuickLogDraft(replacing: first)
        let cleared = try XCTUnwrap(model.quickLogDraft)
        XCTAssertFalse(cleared.hasUserEdits)
        XCTAssertNil(try cleared.clearRecovery?.restoredDraft().batch)
        try await model.selectQuickLogBatchItem(secondID, replacing: cleared)
        _ = try await BatchReviewTestSupport.saveCurrent(model)
        try await model.selectQuickLogBatchItem(firstID, replacing: XCTUnwrap(model.quickLogDraft))
        let current = try XCTUnwrap(model.quickLogDraft)
        try await model.restoreClearedQuickLogDraft(replacing: current)
        XCTAssertEqual(model.quickLogDraft?.amountText, "13.70")
        XCTAssertEqual(model.quickLogDraft?.batch?.items.count, 2)
        XCTAssertFalse(model.quickLogDraft?.batch?.items.contains(where: { $0.id == secondID }) ?? true)
        model.updateQuickLogDraft(cleared)
        XCTAssertEqual(model.quickLogDraft?.amountText, "13.70")
        await fixture.store.close()
    }

    @MainActor
    func testUnrelatedJournalWriteDoesNotConsumeBatch() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = try await BatchReviewTestSupport.start(fixture)
        let draft = model.quickLogDraft
        _ = try await model.logExpense(amount: 99, accountID: fixture.wallet.id, categoryID: fixture.food.id,
            occurredAt: BatchReviewTestSupport.now, payee: "Other action", note: nil)
        XCTAssertEqual(model.quickLogDraft, draft)
        await fixture.store.close()
    }

    @MainActor
    func testQueueSurvivesEncryptedBackupAndRestore() async throws {
        let source = try AppModelFixture(), target = try AppModelFixture()
        defer { source.removeFiles(); target.removeFiles() }
        let model = try await BatchReviewTestSupport.start(source)
        let original = try XCTUnwrap(model.quickLogDraft)
        let file = source.directoryURL.appendingPathComponent("batch.moneyup")
        let password = "Batch review recovery 2026!"
        try await model.encryptedBackup(to: file, password: password)
        let restored = target.model()
        let ticket = try await restored.prepareEncryptedRestorePreview(from: file, password: password)
        try await restored.restoreEncryptedBackup(ticket, password: password)
        XCTAssertEqual(restored.quickLogDraft, original)
        _ = try await BatchReviewTestSupport.saveCurrent(restored)
        XCTAssertEqual(restored.quickLogDraft?.batch?.items.count, 2)
        await source.store.close()
        await target.store.close()
    }

    @MainActor
    func testRemoveOnlyCurrentDraftAndRejectDestructiveLedgerChangesToQueuedReferences() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = try await BatchReviewTestSupport.start(fixture)
        do { try await model.setLedgerItemArchived(id: fixture.usAccount.id, isArchived: true); XCTFail("Queued account is in use") }
        catch { }
        let first = try XCTUnwrap(model.quickLogDraft)
        try await model.removeQuickLogBatchItem(replacing: first)
        XCTAssertEqual(model.quickLogDraft?.batch?.items.count, 2)
        XCTAssertEqual(model.quickLogDraft?.batch?.selectedOrdinal, 2)
        let count = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(count, 0)
        do { try await model.removeQuickLogBatchItem(replacing: first); XCTFail("Stale remove must fail") }
        catch { }
        await fixture.store.close()
    }

    @MainActor
    func testFailedQueueWritePreservesEveryDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = try await BatchReviewTestSupport.start(fixture)
        let current = try XCTUnwrap(model.quickLogDraft)
        await fixture.store.close()
        do {
            try await model.selectQuickLogBatchItem(XCTUnwrap(current.batch?.items[1].id), replacing: current)
            XCTFail("Closed storage must not publish queue navigation")
        } catch { XCTAssertEqual(model.quickLogDraft, current) }
    }
}

private actor BatchCommitGate {
    private var reached = false
    private var ready: [CheckedContinuation<Void, Never>] = []
    private var waiting: CheckedContinuation<Void, Never>?
    func pause() async {
        reached = true
        ready.forEach { $0.resume() }; ready = []
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilReached() async { if !reached { await withCheckedContinuation { ready.append($0) } } }
    func release() { waiting?.resume(); waiting = nil }
}
