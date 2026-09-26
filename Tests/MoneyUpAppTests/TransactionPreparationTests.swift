import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class TransactionPreparationTests: XCTestCase {
    @MainActor
    func testRepeatAndRefundPrepareExactDraftWithoutPostingOrChangingOriginal() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 12.34)
        let now = Date(timeIntervalSince1970: 1_783_411_200)
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food], entries: [original])
        let model = fixture.model(entries: [original], currentDate: { now })
        let balances = model.accountBalancesResult().value
        for action in [TransactionPreparationAction.repeatEntry, .refund] {
            try await model.prepareTransaction(from: original, action: action, replacing: model.quickLogDraft)
            let draft = try XCTUnwrap(model.quickLogDraft)
            XCTAssertEqual(draft.kind, action == .refund ? .refund : .expense)
            XCTAssertEqual(draft.amountText, "12.34")
            XCTAssertEqual(draft.accountID, fixture.wallet.id)
            XCTAssertEqual(draft.occurredAt, now)
            XCTAssertNil(draft.sourceCaptureID)
            let stored = try await fixture.store.fetch(QuickLogDraft.self, id: "current", from: .quickLogDrafts)
            XCTAssertEqual(stored, draft)
            let source = try await fixture.store.fetch(JournalEntry.self, id: original.id.uuidString, from: .journalEntries)
            XCTAssertEqual(source, original)
            let count = try await fixture.store.count(in: .journalEntries)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(model.accountBalancesResult().value, balances)
        }
        await fixture.store.close()
    }

    @MainActor
    func testChangedDraftOrSourceCannotBeReplacedUsingOldConsent() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 4)
        let prior = draft(amount: "1.")
        var latest = prior
        latest.amountText = "1.20"
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food], entries: [original], quickLogDraft: latest)
        let model = fixture.model(entries: [original], quickLogDraft: latest)
        do {
            try await model.prepareTransaction(from: original, action: .repeatEntry, replacing: prior)
            XCTFail("Must retain the newer draft")
        } catch { XCTAssertEqual(model.quickLogDraft, latest) }
        try await fixture.store.remove(id: original.id.uuidString, from: .journalEntries)
        do {
            try await model.prepareTransaction(from: original, action: .refund, replacing: latest)
            XCTFail("Deleted source cannot prepare a refund")
        } catch { XCTAssertEqual(model.quickLogDraft, latest) }
        let persisted = try await fixture.store.fetch(QuickLogDraft.self, id: "current", from: .quickLogDrafts)
        XCTAssertEqual(persisted, latest)
        await fixture.store.close()
    }

    func testReceiptPrefillProtectsExistingValuesAndExplicitChoices() {
        var entry = draft(amount: "12.")
        entry.payee = "My merchant"
        entry.note = "Manual notes"
        entry.dateWasEdited = true
        let protected = QuickLogReceiptPrefillPolicy.protectedFields(
            draft: entry, accountWasEdited: true, categoryWasEdited: true)
        for field: PartialKeyPath<QuickLogDraft> in [\.amountText, \.payee, \.note, \.occurredAt, \.accountID, \.categoryID] {
            XCTAssertTrue(protected.contains(field))
        }
        let fresh = QuickLogReceiptPrefillPolicy.protectedFields(
            draft: draft(amount: ""), accountWasEdited: false, categoryWasEdited: false)
        XCTAssertTrue(fresh.isEmpty)
    }

    @MainActor
    func testDecimalDraftAndExplicitTimestampSurviveImmediateLock() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        var entry = draft(amount: "")
        entry.accountID = fixture.wallet.id
        entry.categoryID = fixture.food.id
        entry.occurredAt = Date(timeIntervalSince1970: 1_741_507_199) // DST boundary fixture.
        entry.dateWasEdited = true
        for typed in ["1", "1.", "1.0", "1.00"] {
            entry.amountText = typed
            model.updateQuickLogDraft(entry)
            XCTAssertEqual(model.quickLogDraft?.amountText, typed)
        }
        model.lockManually()
        await model.waitForPendingStoreClose()
        let reopened = try fixture.reopenStore()
        let restored = try await reopened.fetch(QuickLogDraft.self, id: "current", from: .quickLogDrafts)
        XCTAssertEqual(restored, entry)
        await reopened.close()
    }

    func testExplicitChoicesSurviveRoundTripWithoutFreezingFreshTime() throws {
        var entry = draft(amount: "")
        entry.accountID = UUID()
        entry.categoryID = UUID()
        XCTAssertFalse(entry.hasUserEdits, "Automatic defaults alone are replaceable")
        entry.accountWasEdited = true
        entry.categoryWasEdited = true
        XCTAssertTrue(entry.hasUserEdits)
        XCTAssertFalse(entry.hasTransactionContent)
        XCTAssertTrue(QuickLogOccurrencePolicy.shouldRefresh(
            hasTransactionContent: entry.hasTransactionContent,
            dateWasEdited: entry.dateWasEdited, sourceCaptureID: entry.sourceCaptureID))
        let encoded = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(QuickLogDraft.self, from: encoded), entry)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "accountWasEdited")
        legacy.removeValue(forKey: "categoryWasEdited")
        let restored = try JSONDecoder().decode(QuickLogDraft.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.accountWasEdited)
        XCTAssertTrue(restored.categoryWasEdited)
        XCTAssertTrue(restored.hasUserEdits)
    }

    /// Every quick action and kind-segment tap records the kind as a manual
    /// smart-entry field. That is routing, not content: it must never make an
    /// empty Log form count as an unfinished entry (build 1059.1 feedback).
    func testChoosingOnlyTheEntryKindIsNotAnUnfinishedEntry() throws {
        var entry = draft(amount: "")
        entry.smartState.edited(.kind)
        XCTAssertFalse(entry.hasUserEdits)
        XCTAssertFalse(entry.hasTransactionContent)
        XCTAssertFalse(PendingCaptureHistorySection.isVisible(
            pendingLockedCaptureCount: 0, draft: entry
        ))
        XCTAssertTrue(PendingCaptureHistorySection.isVisible(
            pendingLockedCaptureCount: 1, draft: entry
        ))
        entry.smartState.edited(.payee)
        XCTAssertTrue(entry.hasUserEdits, "Other manual fields still protect the draft")
        var typed = draft(amount: "4")
        typed.smartState.edited(.kind)
        XCTAssertTrue(typed.hasUserEdits)
        // A draft with input is shown in Log itself; History never nags about it.
        XCTAssertFalse(PendingCaptureHistorySection.isVisible(
            pendingLockedCaptureCount: 0, draft: typed
        ))
        // A blank draft record exists as soon as Log has been opened once.
        XCTAssertFalse(PendingCaptureHistorySection.isVisible(
            pendingLockedCaptureCount: 0, draft: draft(amount: "")
        ))
        XCTAssertFalse(PendingCaptureHistorySection.isVisible(
            pendingLockedCaptureCount: 0, draft: nil
        ))
    }

    /// 1075.1 feedback: every widget tap asked about an "unfinished
    /// transaction" over a form holding only an account and a category.
    /// Choices and touched-then-emptied fields are not an entry; only
    /// something a new entry would throw away is.
    func testOnlyRealContentIsAnUnfinishedEntry() throws {
        var entry = draft(amount: "")
        entry.accountID = UUID()
        entry.categoryID = UUID()
        entry.accountWasEdited = true
        entry.categoryWasEdited = true
        for field in [QuickLogSmartField.account, .category, .amount, .payee, .note, .date, .kind] {
            entry.smartState.edited(field)
        }
        XCTAssertTrue(entry.hasUserEdits, "The choices themselves are still kept")
        XCTAssertFalse(entry.isUnfinishedEntry, "No amount, payee, note or date: nothing to lose")

        for content in [\QuickLogDraft.amountText, \.destinationAmountText, \.payee, \.note, \.smartText] {
            var typed = entry
            typed[keyPath: content] = "4"
            XCTAssertTrue(typed.isUnfinishedEntry)
            typed[keyPath: content] = "  "
            XCTAssertFalse(typed.isUnfinishedEntry, "Whitespace is not content")
        }
        var dated = entry
        dated.dateWasEdited = true
        XCTAssertTrue(dated.isUnfinishedEntry)
        var allowance = entry
        allowance.selectedAllowanceID = UUID()
        XCTAssertTrue(allowance.isUnfinishedEntry)
        var split = entry
        split.splitLines = [QuickLogSplitDraftLine(categoryID: UUID(), amountText: "", memo: "")]
        XCTAssertTrue(split.isUnfinishedEntry)
        var capture = entry
        capture.sourceCaptureID = UUID()
        XCTAssertTrue(capture.isUnfinishedEntry, "A waiting capture is never discarded silently")
        XCTAssertFalse(draft(amount: "").isUnfinishedEntry)
    }

    private func draft(amount: String) -> QuickLogDraft {
        QuickLogDraft(kind: .expense, amountText: amount, destinationAmountText: "",
            accountID: nil, destinationAccountID: nil, categoryID: nil,
            occurredAt: Date(timeIntervalSince1970: 1_000), dateWasEdited: false,
            payee: "", note: "", smartText: "")
    }
}
