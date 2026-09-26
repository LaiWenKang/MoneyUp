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
        // Routed through the book's own accounts: the model never persists a
        // draft reference the book lacks, which made backups unrestorable.
        var current = draft()
        current.kind = .expense
        current.accountID = fixture.wallet.id
        current.destinationAccountID = fixture.usAccount.id
        current.categoryID = fixture.food.id
        current.splitLines[0].categoryID = fixture.food.id
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
        var expectedCleared = current.cleared(at: now)
        expectedCleared.clearRecovery = cleared.clearRecovery
        XCTAssertEqual(cleared, expectedCleared)
        XCTAssertEqual(try cleared.clearRecovery?.restoredDraft(), edited)
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

    /// Build 1059.1 feedback: a draft record exists as soon as Log has been
    /// opened, so a widget capture made while locked was never promoted and
    /// History announced it forever. A blank routing draft must yield.
    @MainActor
    func testBlankDraftYieldsToLockedCaptureButEditedDraftDoesNot() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(kind: .expense, amountText: "12.50", payee: "Kiosk")
        let inbox = InMemoryLockedCaptureStore(captures: [capture])
        var blank = QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "", accountID: UUID(),
            destinationAccountID: nil, categoryID: UUID(), occurredAt: Date(), dateWasEdited: false,
            payee: "", note: "", smartText: "")
        blank.smartState.edited(.kind)
        XCTAssertFalse(blank.hasUserEdits, "Kind plus default account and category is routing only")
        let model = fixture.model(quickLogDraft: blank, lockedCaptureStore: inbox)
        try await model.promotePendingLockedCapture()
        let promoted = try XCTUnwrap(model.quickLogDraft)
        XCTAssertEqual(promoted.sourceCaptureID, capture.id)
        XCTAssertEqual(promoted.amountText, "12.50")
        XCTAssertEqual(promoted.payee, "Kiosk")
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        let remaining = try await inbox.all()
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(model.requestedQuickLogMode, .expense, "Unlock routes straight into Log")

        let second = LockedCapture(kind: .expense, amountText: "3", payee: "Later")
        let secondInbox = InMemoryLockedCaptureStore(captures: [second])
        var typed = draft()
        typed.amountText = "9"
        let busy = fixture.model(quickLogDraft: typed, lockedCaptureStore: secondInbox)
        try await busy.promotePendingLockedCapture()
        XCTAssertEqual(busy.quickLogDraft, typed, "Real input is never replaced silently")
        XCTAssertEqual(busy.pendingLockedCaptureCount, 1)
        XCTAssertTrue(PendingCaptureHistorySection.isVisible(
            pendingLockedCaptureCount: busy.pendingLockedCaptureCount, draft: busy.quickLogDraft
        ))
    }

    @MainActor
    func testDiscardingPendingCapturesEmptiesInboxWithoutTouchingDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let captures = [
            LockedCapture(kind: .expense, amountText: "1", payee: "One"),
            LockedCapture(kind: .income, amountText: "2", payee: "Two")
        ]
        let inbox = InMemoryLockedCaptureStore(captures: captures)
        var typed = draft()
        typed.amountText = "9"
        let model = fixture.model(quickLogDraft: typed, lockedCaptureStore: inbox)
        try await model.promotePendingLockedCapture()
        XCTAssertEqual(model.pendingLockedCaptureCount, 2)
        try await model.discardPendingLockedCaptures()
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        let remainingAfterDiscard = try await inbox.all()
        XCTAssertEqual(remainingAfterDiscard, [])
        XCTAssertEqual(model.quickLogDraft, typed)
        XCTAssertFalse(PendingCaptureHistorySection.isVisible(
            pendingLockedCaptureCount: 0, draft: typed.cleared(at: Date())
        ))
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
