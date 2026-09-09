import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class QuickLogFlowReliabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_933_600)

    private func draft(_ phrase: String, fixture: AppModelFixture) -> QuickLogDraft {
        QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "", accountID: fixture.wallet.id,
            destinationAccountID: fixture.usAccount.id, categoryID: fixture.food.id, occurredAt: now,
            dateWasEdited: false, payee: "", note: "", smartText: phrase)
    }

    func testReinterpretationUpdatesAutomaticValuesButKeepsManualCorrections() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let newCategory = LedgerAccount(name: "New category", kind: .expense)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, newCategory]
        var current = draft("lunch 12 Wallet Food yesterday; with Sam", fixture: fixture)
        current.categoryID = nil
        current = QuickLogUnderstandingFill.fill(SmartEntryInterpreter.interpret(current.smartText, accounts: accounts, now: now),
            current: current, accounts: accounts, now: now)
        XCTAssertEqual(decimalAmount(from: current.amountText), 12)
        XCTAssertTrue(current.smartState.automaticFields.contains(.amount))
        current.payee = "My corrected merchant"
        current.smartState.edited(.payee)
        current.categoryID = newCategory.id
        current.categoryWasEdited = true
        current.smartState.edited(.category)
        current.smartText = "dinner 18 Wallet Food today; with Mei"
        let updated = QuickLogUnderstandingFill.fill(SmartEntryInterpreter.interpret(current.smartText, accounts: accounts, now: now),
            current: current, accounts: accounts, now: now)
        XCTAssertEqual(decimalAmount(from: updated.amountText), 18)
        XCTAssertEqual(updated.payee, "My corrected merchant")
        XCTAssertEqual(updated.categoryID, newCategory.id)
        XCTAssertEqual(updated.note, "with Mei")
        XCTAssertEqual(updated.occurredAt, now)
        XCTAssertEqual(updated.smartState.referenceDate, now)
        XCTAssertEqual(try JSONDecoder().decode(QuickLogDraft.self, from: JSONEncoder().encode(updated)), updated)
        XCTAssertTrue(updated.smartState.issues.isEmpty)
    }

    func testTransferAndSplitUseTheExistingExactEditableDraft() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let transport = LedgerAccount(name: "Transport", kind: .expense)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, transport]
        let transfer = "transfer SGD10 from Wallet to USD Cash received USD7.50"
        let moved = QuickLogUnderstandingFill.fill(SmartEntryInterpreter.interpret(transfer, accounts: accounts),
            current: draft(transfer, fixture: fixture), accounts: accounts, now: now)
        XCTAssertEqual(moved.kind, .transfer)
        XCTAssertEqual(decimalAmount(from: moved.amountText), 10)
        XCTAssertEqual(decimalAmount(from: moved.destinationAmountText), Decimal(string: "7.50"))
        XCTAssertEqual(moved.destinationAccountID, fixture.usAccount.id)
        XCTAssertTrue(moved.smartState.issues.isEmpty)
        let shortPhrase = "SGD10 to USD Cash received USD7.50"
        var visibleTransfer = draft(shortPhrase, fixture: fixture)
        visibleTransfer.kind = .transfer
        visibleTransfer.accountWasEdited = true
        visibleTransfer.smartState.edited(.kind)
        visibleTransfer.smartState.edited(.account)
        let contextual = QuickLogUnderstandingFill.fill(
            SmartEntryInterpreter.interpret(shortPhrase, accounts: accounts, expectsTransfer: true),
            current: visibleTransfer, accounts: accounts, now: now)
        XCTAssertEqual(contextual.accountID, fixture.wallet.id)
        XCTAssertEqual(contextual.destinationAccountID, fixture.usAccount.id)
        XCTAssertTrue(contextual.smartState.issues.isEmpty)
        let phrase = "split Wallet Food12 + Transport8"
        let split = QuickLogUnderstandingFill.fill(SmartEntryInterpreter.interpret(phrase, accounts: accounts),
            current: draft(phrase, fixture: fixture), accounts: accounts, now: now)
        XCTAssertEqual(decimalAmount(from: split.amountText), 20)
        XCTAssertEqual(split.splitLines.count, 2)
        XCTAssertTrue(split.smartState.issues.isEmpty)
    }

    @MainActor
    func testClearRecoverySurvivesBackgroundAndReopenWithoutChangingSavedEntries() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = draft("lunch 12 Wallet yesterday", fixture: fixture)
        let entry = try fixture.expense(amount: 7)
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd), accounts: [fixture.wallet, fixture.food],
            entries: [entry], quickLogDraft: original)
        let model = fixture.model(entries: [entry], quickLogDraft: original)
        try await model.clearQuickLogDraft(replacing: original)
        model.lockManually()
        await model.waitForPendingStoreClose()
        let store = try fixture.reopenStore()
        let storedDraft = try await store.fetch(QuickLogDraft.self, id: "current", from: .quickLogDrafts)
        let cleared = try XCTUnwrap(storedDraft)
        let resumed = fixture.model(store: store, entries: [entry], quickLogDraft: cleared)
        try await resumed.restoreClearedQuickLogDraft(replacing: cleared)
        XCTAssertEqual(resumed.quickLogDraft, original)
        let saved = try await store.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(saved, [entry])
        await store.close()
    }

    @MainActor
    func testUndoClearCannotOverwriteANewerDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = draft("lunch 12", fixture: fixture)
        let model = fixture.model(quickLogDraft: original)
        try await model.clearQuickLogDraft(replacing: original)
        let cleared = try XCTUnwrap(model.quickLogDraft)
        var edited = cleared
        edited.amountText = "99"
        model.updateQuickLogDraft(edited)
        do { try await model.restoreClearedQuickLogDraft(replacing: cleared); XCTFail("Stale recovery must fail") }
        catch { XCTAssertEqual(model.quickLogDraft, edited) }
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }

    @MainActor
    func testClearAndRapidEditsCancelOlderParsingWithoutOverlappingWorkers() async {
        let coordinator = QuickLogParseCoordinator()
        let gate = LoggingFlowGate()
        let firstValue = SmartEntryInterpreter.interpret("lunch 12", accounts: [])
        let secondValue = SmartEntryInterpreter.interpret("dinner 18", accounts: [])
        let first = Task { await coordinator.resolve { await gate.suspend(); return firstValue } }
        await gate.waitUntilReached()
        coordinator.cancel()
        let second = Task { await coordinator.resolve { secondValue } }
        await gate.release()
        let obsolete = await first.value
        let current = await second.value
        XCTAssertNil(obsolete)
        XCTAssertEqual(current, secondValue)
        coordinator.cancel()
        let resumed = await coordinator.resolve { firstValue }
        XCTAssertEqual(resumed, firstValue)
    }

    @MainActor
    func testRepeatedSaveDuringCommitPostsOnceAndRetainsNoStaleDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = LoggingFlowGate()
        let model = fixture.model(lifecycleHooks: AppModelLifecycleHooks { point in
            if point == .beforeJournalCommit { await gate.suspend() }
        })
        let instant = now
        let first = Task { try await model.logExpense(amount: 12, accountID: fixture.wallet.id,
            categoryID: fixture.food.id, occurredAt: instant, payee: "Cafe", note: nil) }
        await gate.waitUntilReached()
        do {
            _ = try await model.logExpense(amount: 12, accountID: fixture.wallet.id,
                categoryID: fixture.food.id, occurredAt: instant, payee: "Cafe", note: nil)
            XCTFail("The overlapping save must not post")
        } catch { }
        await gate.release()
        _ = try await first.value
        let entries = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(model.quickLogDraft)
        await fixture.store.close()
    }

    @MainActor
    func testMerchantLearningCanBeDisabledWithoutErasingConfirmedEntries() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entries = try (0..<4).map { try fixture.expense(amount: 12, occurredAt: now.addingTimeInterval(Double(-$0 * 86_400)), payee: "Cafe") }
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd), accounts: [fixture.wallet, fixture.food], entries: entries)
        let model = fixture.model(entries: entries)
        let query = CaptureSuggestionQuery(kind: .expense, payee: "Cafe", currency: fixture.sgd, occurredAt: now)
        let learned = await model.indexedCaptureSuggestion(for: query, eligibleCategoryIDs: [fixture.food.id])
        XCTAssertEqual(learned.categorySuggestion?.ledgerAccountID, fixture.food.id)
        try await model.updateMerchantSuggestions(false)
        let disabled = await model.indexedCaptureSuggestion(for: query, eligibleCategoryIDs: [fixture.food.id])
        XCTAssertNil(disabled.categorySuggestion)
        XCTAssertEqual(model.entries, entries)
        try await model.updateMerchantSuggestions(true)
        let enabled = await model.indexedCaptureSuggestion(for: query, eligibleCategoryIDs: [fixture.food.id])
        XCTAssertEqual(enabled.categorySuggestion?.ledgerAccountID, fixture.food.id)
        await fixture.store.close()
    }
}

private actor LoggingFlowGate {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        reached = true
        reachedWaiters.forEach { $0.resume() }; reachedWaiters = []
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilReached() async {
        if !reached { await withCheckedContinuation { reachedWaiters.append($0) } }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters = []
    }
}
