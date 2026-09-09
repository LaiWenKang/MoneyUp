import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class QuickLogDraftClearingTests: XCTestCase {
    private func draft() -> QuickLogDraft {
        QuickLogDraft(kind: .transfer, amountText: "12.00", destinationAmountText: "9.30",
            accountID: UUID(), destinationAccountID: UUID(), categoryID: UUID(),
            occurredAt: Date(timeIntervalSince1970: 1_000), dateWasEdited: true,
            payee: "My title", note: "My description", smartText: "unfinished phrase",
            splitLines: [QuickLogSplitDraftLine(categoryID: UUID(), amountText: "12", memo: "Keep until confirmed", isLocked: true)],
            selectedAllowanceID: UUID(), accountWasEdited: true, categoryWasEdited: true)
    }

    @MainActor
    func testClearPersistsBeforePublicationAndPreservesJournalAndRouting() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 12.34)
        let current = draft()
        let now = Date(timeIntervalSince1970: 2_000)
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food], entries: [original], quickLogDraft: current)
        let model = fixture.model(entries: [original], quickLogDraft: current, currentDate: { now })
        let balances = model.accountBalancesResult().value
        // A queued older draft write must finish before the confirmed clear.
        var edited = current
        edited.note = "last keystroke"
        model.updateQuickLogDraft(edited)
        try await model.clearQuickLogDraft(replacing: edited)
        let cleared = try XCTUnwrap(model.quickLogDraft)
        XCTAssertEqual(cleared, current.cleared(at: now))
        XCTAssertFalse(cleared.hasUserEdits)
        XCTAssertEqual(cleared.kind, current.kind)
        XCTAssertEqual(cleared.accountID, current.accountID)
        XCTAssertEqual(cleared.destinationAccountID, current.destinationAccountID)
        XCTAssertEqual(cleared.categoryID, current.categoryID)
        XCTAssertEqual(model.entries, [original])
        XCTAssertEqual(model.accountBalancesResult().value, balances)
        let persisted = try await fixture.store.fetch(QuickLogDraft.self, id: "current", from: .quickLogDrafts)
        XCTAssertEqual(persisted, cleared)
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let restored = try await reopened.fetch(QuickLogDraft.self, id: "current", from: .quickLogDrafts)
        XCTAssertEqual(restored, cleared)
        let saved = try await reopened.fetch(JournalEntry.self, id: original.id.uuidString, from: .journalEntries)
        XCTAssertEqual(saved, original)
        await reopened.close()
    }

    @MainActor
    func testStaleConfirmationCannotClearLaterEdits() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let prior = draft()
        var latest = prior
        latest.amountText = "14.25"
        let model = fixture.model(quickLogDraft: latest)
        do {
            try await model.clearQuickLogDraft(replacing: prior)
            XCTFail("Stale confirmation must fail")
        } catch { XCTAssertEqual(model.quickLogDraft, latest) }
        await fixture.store.close()
    }

    @MainActor
    func testWriteFailureKeepsTheUnfinishedForm() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let current = draft()
        let model = fixture.model(quickLogDraft: current)
        await fixture.store.close()
        do {
            try await model.clearQuickLogDraft(replacing: current)
            XCTFail("Closed storage must not report success")
        } catch { XCTAssertEqual(model.quickLogDraft, current) }
        XCTAssertFalse(model.isLifecycleMutationInProgress)
    }

    @MainActor
    func testClearCurrentCaptureKeepsOtherPendingCaptures() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let first = LockedCapture(kind: .expense, amountText: "10", payee: "Current")
        let second = LockedCapture(kind: .expense, amountText: "20", payee: "Next")
        let inbox = InMemoryLockedCaptureStore(captures: [first, second])
        var current = draft()
        current.sourceCaptureID = first.id
        let model = fixture.model(quickLogDraft: current, lockedCaptureStore: inbox)
        try await model.clearQuickLogDraft(replacing: current)
        let remaining = try await inbox.all()
        XCTAssertEqual(remaining, [second])
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)
        XCTAssertNil(model.quickLogDraft?.sourceCaptureID)
        XCTAssertFalse(try XCTUnwrap(model.quickLogDraft).hasUserEdits)
        await fixture.store.close()
    }
}
