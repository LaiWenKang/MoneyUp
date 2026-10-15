import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import SwiftUI
import UIKit
import XCTest

/// The Log → History round trip never fails silently: Save is never stranded
/// or ignored without a reason, filters never move the chosen range, and the
/// editor writes a revision only for a real, valid change. Fictional data only.
final class RoundTripReliabilityTests: XCTestCase {
    private typealias ScopePolicy = HistoryFilterScopePolicy
    private let now = Date(timeIntervalSince1970: 1_788_933_600)
    private let us = Locale(identifier: "en_US")

    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        return calendar
    }

    private func filters(_ range: HistoryQuickRange, calendar: Calendar) -> HistoryFilterDraft {
        var draft = HistoryFilterDraft(now: now, calendar: calendar)
        draft.applyQuickRange(range, asOf: now, calendar: calendar)
        return draft
    }

    // MARK: - Amount input: one rule and one wording for Log and the editor

    func testAmountIssuesFollowCurrencyPrecisionAndTheNewWriteCeiling() throws {
        let usd = try CurrencyCode("USD"), jpy = try CurrencyCode("JPY"), kwd = try CurrencyCode("KWD")
        func issue(_ text: String, _ currency: CurrencyCode?, editing: Bool = false) -> MoneyInputIssue? {
            MoneyInputIssue.of(text, currency: currency, isEditing: editing, locale: us)
        }
        XCTAssertNil(issue("", usd))
        XCTAssertNil(issue("   ", usd))
        XCTAssertNil(issue("12.34", usd))
        XCTAssertNil(issue(" 12.30 ", usd))
        // More decimals than the currency has is refused, never rounded or rescaled.
        XCTAssertEqual(issue("12.345", usd), .precision(usd))
        XCTAssertEqual(issue("12.5", jpy), .precision(jpy))
        XCTAssertNil(issue("1250", jpy))
        XCTAssertNil(issue("1.234", kwd))
        XCTAssertEqual(issue("1.2345", kwd), .precision(kwd))
        // Fifteen whole digits is the ceiling for a new amount.
        XCTAssertNil(issue("999999999999999", usd))
        XCTAssertNil(issue("999999999999999.00", usd))
        XCTAssertEqual(issue("999999999999999.01", usd), .tooLarge)
        XCTAssertEqual(issue("1000000000000000", usd), .tooLarge)
        for text in ["abc", "0", "0.00", "-5", "1e3", "12.", ".", "1,234.50", "$12"] {
            XCTAssertEqual(issue(text, usd), .invalid, text)
        }
        // A prefix still being typed into the focused field is not an error yet.
        for text in ["12.", "0", "0.", "0.0"] {
            XCTAssertNil(issue(text, usd, editing: true), text)
        }
        // Before an account is chosen only the shape of the number is checked.
        XCTAssertNil(issue("12.345", nil))
        XCTAssertEqual(issue("abc", nil), .invalid)
    }

    func testAnUntouchedLegacyAmountStaysSaveableInTheEditor() throws {
        let usd = try CurrencyCode("USD")
        // Equal by value although written with a different scale.
        let legacy = try XCTUnwrap(Decimal(string: "12.3450"))
        XCTAssertNil(MoneyInputIssue.of("12.345", currency: usd, preservedAmounts: [legacy], locale: us))
        XCTAssertEqual(
            MoneyInputIssue.of("12.346", currency: usd, preservedAmounts: [legacy], locale: us),
            .precision(usd)
        )
        XCTAssertEqual(MoneyInputIssue.of("0", currency: usd, preservedAmounts: [0], locale: us), .invalid)
    }

    func testFieldMessagesKeepTheWordingLogAlreadyUsed() throws {
        let usd = try CurrencyCode("USD")
        XCTAssertEqual(MoneyInputIssue.invalid.message, AppLocalization.string("error.invalid_amount"))
        XCTAssertEqual(
            MoneyInputIssue.precision(usd).message,
            MoneyError.unsupportedPrecision(currency: usd).errorDescription
        )
        XCTAssertTrue(MoneyInputIssue.precision(usd).message.contains("USD"))
        XCTAssertEqual(MoneyInputIssue.tooLarge.message, AppLocalization.string("error.amount_too_large"))
    }

    // MARK: - Log: a refused Smart Entry reading never strands Save

    func testARefusedReadingNeverBlocksSaveAndClearsWhenTheTextChanges() {
        for refused in [[SmartEntryIssue.multiple], [.inputLimit], [.amount, .multiple]] {
            var state = QuickLogSmartState()
            state.hasPreview = true
            state.issues = refused
            XCTAssertFalse(state.blocksSave, "\(refused)")
            // No field maps to these issues, so field edits cannot clear them.
            state.edited(.amount)
            state.edited(.category)
            XCTAssertTrue(state.isRefusedReading, "\(refused)")
            state.smartTextChanged()
            XCTAssertEqual(state.issues, [], "\(refused)")
            XCTAssertFalse(state.hasPreview, "\(refused)")
        }
    }

    func testIssuesFromAFilledReadingStillWaitForTheirField() {
        var state = QuickLogSmartState()
        state.hasPreview = true
        state.issues = [.category]
        XCTAssertTrue(state.blocksSave)
        state.smartTextChanged()
        XCTAssertEqual(state.issues, [.category], "Editing the phrase does not settle a filled field")
        XCTAssertTrue(state.hasPreview)
        state.edited(.category)
        XCTAssertFalse(state.blocksSave)
    }

    func testSeveralLinesFillNothingAndLeaveTypedFieldsSaveable() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food]
        let typed = QuickLogDraft(kind: .expense, amountText: "8.50", destinationAmountText: "", accountID: fixture.wallet.id,
            destinationAccountID: fixture.usAccount.id, categoryID: fixture.food.id, occurredAt: now,
            dateWasEdited: false, payee: "", note: "", smartText: "coffee 5\nlunch 12")
        let interpretation = SmartEntryInterpreter.interpret(typed.smartText, accounts: accounts, now: now)
        XCTAssertEqual(interpretation.shape, .multiple)
        let filled = QuickLogUnderstandingFill.fill(interpretation, current: typed, accounts: accounts, now: now)
        XCTAssertEqual(filled.amountText, "8.50")
        XCTAssertEqual(filled.categoryID, fixture.food.id)
        XCTAssertEqual(filled.smartState.issues, [.multiple])
        XCTAssertFalse(filled.smartState.blocksSave, "The typed entry must stay saveable")
    }

    /// Log after a refused multi-line reading over typed fields: the notice
    /// stays and Save is offered. Hosting-controller renders for review in
    /// the CI attachments, not device screenshots.
    @MainActor
    func testRenderRefusedReadingOverTypedFields() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let previousPrivacy = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previousPrivacy { UserDefaults.standard.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        let model = fixture.model()
        let accounts = model.accounts
        let typed = QuickLogDraft(kind: .expense, amountText: "8.50", destinationAmountText: "", accountID: fixture.wallet.id,
            destinationAccountID: nil, categoryID: fixture.food.id, occurredAt: now,
            dateWasEdited: false, payee: "", note: "", smartText: "coffee 5\nlunch 12")
        model.updateQuickLogDraft(QuickLogUnderstandingFill.fill(
            SmartEntryInterpreter.interpret(typed.smartText, accounts: accounts, now: now),
            current: typed, accounts: accounts, now: now))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let priorWindow = scene.windows.first { $0.isKeyWindow }
        defer {
            MoneyUpKeyboard.dismiss()
            window.isHidden = true
            window.rootViewController = nil
            priorWindow?.makeKey()
        }
        for (language, width) in [("en", CGFloat(390)), ("zh-Hans", CGFloat(320))] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            let view = QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false, isActive: false,
                launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in })
                .environment(model)
                .environment(\.locale, Locale(identifier: language))
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(500))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "round-trip-refused-reading-\(language)-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let saved = model.entries.count
            XCTAssertEqual(saved, 0, "Rendering never saves")
        }
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }

    // MARK: - History: filters and Clear never move the chosen range

    func testApplyingAFilterKeepsTheRangeSoSearchStillReachesEveryDate() throws {
        let calendar = try utcCalendar()
        for range in HistoryQuickRange.allCases {
            let current = filters(range, calendar: calendar)
            var updated = current
            updated.categoryIDs = [UUID()]
            updated.kind = .expense
            let kept = ScopePolicy.range(afterApplying: updated, over: current, selected: range, calendar: calendar)
            XCTAssertEqual(kept, range, "\(range)")
            // The badge counts the two new filters, not the visible range.
            XCTAssertEqual(updated.advancedFilterCount(quickRange: kept), 2, "\(range)")
        }
        // Applied over Today, an income filter leaves Today rolling, so a
        // search still widens to every date and hands Today back when cleared.
        let today = filters(.today, calendar: calendar)
        var incomeOnly = today
        incomeOnly.kind = .income
        let range = ScopePolicy.range(afterApplying: incomeOnly, over: today, selected: .today, calendar: calendar)
        let searching = HistorySearchScopePolicy.applying(search: "kopi", after: "", to: .init(range: range))
        XCTAssertEqual(searching, .init(range: .all, rangeBeforeSearch: .today))
    }

    func testOnlyAChangeOfDaysInTheSheetMakesACustomRange() throws {
        let calendar = try utcCalendar()
        let today = filters(.today, calendar: calendar)
        var laterSameDay = today
        laterSameDay.startDate = now.addingTimeInterval(3_600)
        XCTAssertEqual(ScopePolicy.range(afterApplying: laterSameDay, over: today, selected: .today, calendar: calendar), .today)

        let month = filters(.month, calendar: calendar)
        var earlier = month
        earlier.startDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -40, to: now))
        XCTAssertNil(ScopePolicy.range(afterApplying: earlier, over: month, selected: .month, calendar: calendar))

        var custom = earlier
        custom.kind = .refund
        XCTAssertNil(ScopePolicy.range(afterApplying: custom, over: earlier, selected: nil, calendar: calendar))

        var undated = earlier
        undated.includesStartDate = false
        undated.includesEndDate = false
        XCTAssertEqual(ScopePolicy.range(afterApplying: undated, over: earlier, selected: nil, calendar: calendar), .all)
    }

    func testClearAppearsOnlyForWhatThePersonSetAndKeepsTheirRange() throws {
        let calendar = try utcCalendar()
        let today = filters(.today, calendar: calendar)
        XCTAssertFalse(ScopePolicy.canClear(filters: today, range: .today, searchText: ""))
        XCTAssertFalse(ScopePolicy.canClear(filters: filters(.all, calendar: calendar), range: .all, searchText: ""))
        XCTAssertTrue(ScopePolicy.canClear(filters: today, range: .today, searchText: "kopi"))
        var category = today
        category.categoryIDs = [UUID()]
        XCTAssertTrue(ScopePolicy.canClear(filters: category, range: .today, searchText: ""))
        XCTAssertTrue(ScopePolicy.canClear(filters: today, range: nil, searchText: ""), "Custom dates are a filter")

        XCTAssertEqual(ScopePolicy.rangeAfterClearing(range: .month, rangeBeforeSearch: nil), .month)
        XCTAssertEqual(ScopePolicy.rangeAfterClearing(range: .all, rangeBeforeSearch: .today), .today)
        // Month chosen while a search had widened Today: Clear keeps Month,
        // exactly as ending the search does.
        XCTAssertEqual(ScopePolicy.rangeAfterClearing(range: .month, rangeBeforeSearch: .today), .month)
        XCTAssertEqual(
            HistorySearchScopePolicy.applying(
                search: "", after: "kopi", to: .init(range: .month, rangeBeforeSearch: .today)
            ).range,
            .month
        )
        XCTAssertEqual(ScopePolicy.rangeAfterClearing(range: .all, rangeBeforeSearch: nil), .all)
        XCTAssertEqual(ScopePolicy.rangeAfterClearing(range: nil, rangeBeforeSearch: nil), .all)
    }

    // MARK: - Editor: Save writes once, only for a change

    func testEditorSaveWritesOnlyAChangedFormAndNeverTwice() {
        typealias Policy = TransactionEditSavePolicy
        XCTAssertEqual(Policy.action(isSaving: false, hasMarkedText: false, hasChanges: true), .write)
        XCTAssertEqual(Policy.action(isSaving: false, hasMarkedText: false, hasChanges: false), .close)
        XCTAssertEqual(Policy.action(isSaving: false, hasMarkedText: true, hasChanges: false), .finishComposition)
        XCTAssertEqual(Policy.action(isSaving: false, hasMarkedText: true, hasChanges: true), .finishComposition)
        for marked in [false, true] {
            for changed in [false, true] {
                XCTAssertEqual(Policy.action(isSaving: true, hasMarkedText: marked, hasChanges: changed), .ignore)
            }
        }
    }

    @MainActor
    func testOverlappingEditSavesWriteOneRevision() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food], entries: [original])
        let gate = RoundTripGate()
        let model = fixture.model(entries: [original], lifecycleHooks: AppModelLifecycleHooks { point in
            if point == .afterJournalProjectionInvalidationBeforeCommit { await gate.suspend() }
        })
        let first = Task { try await replaceExpense(original, in: model, fixture: fixture, amount: 20) }
        await gate.waitUntilReached()
        do {
            try await replaceExpense(original, in: model, fixture: fixture, amount: 30)
            XCTFail("A second save while the first is writing must not write")
        } catch AppModelError.transactionInProgress {}
        await gate.release()
        try await first.value
        let live = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
        let revisions = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntryRevisions)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.supersedesID, original.id)
        XCTAssertEqual(revisions.map(\.id), [original.id])
        await fixture.store.close()
    }

    @MainActor
    func testARefusedEditLeavesTheEntryAsItWasAndTheCorrectionSavesExactly() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food], entries: [original])
        let model = fixture.model(entries: [original])
        let tooPrecise = try XCTUnwrap(Decimal(string: "12.345"))
        for refused in [tooPrecise, MonetaryInputPolicy.maximumAbsoluteNewWrite + 1] {
            do {
                try await replaceExpense(original, in: model, fixture: fixture, amount: refused)
                XCTFail("\(refused) must be refused")
            } catch {}
            let shownIDs = model.entries.map(\.id)
            XCTAssertEqual(shownIDs, [original.id], "\(refused)")
            let live = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
            XCTAssertEqual(live, [original], "\(refused)")
            let revisions = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntryRevisions)
            XCTAssertTrue(revisions.isEmpty, "\(refused)")
        }
        // The same form, corrected, saves once with the exact amount typed.
        let corrected = try XCTUnwrap(Decimal(string: "12.34"))
        try await replaceExpense(original, in: model, fixture: fixture, amount: corrected)
        let live = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.supersedesID, original.id)
        let walletLeg = live.first?.postings.first { $0.accountID == fixture.wallet.id }
        XCTAssertEqual(walletLeg.map { abs($0.money.amount) }, corrected)
        XCTAssertEqual(walletLeg?.money.currency, fixture.sgd)
        await fixture.store.close()
    }
}

@MainActor
private func replaceExpense(
    _ original: JournalEntry,
    in model: AppModel,
    fixture: AppModelFixture,
    amount: Decimal
) async throws {
    try await model.replaceEntry(
        id: original.id, kind: .expense, amount: amount, destinationAmount: nil,
        accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: fixture.food.id,
        occurredAt: original.occurredAt, payee: "Cafe", note: "Corrected"
    )
}

/// Holds one save at a checkpoint so a second can arrive while it writes.
private actor RoundTripGate {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        reached = true
        reachedWaiters.forEach { $0.resume() }
        reachedWaiters = []
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitUntilReached() async {
        if !reached { await withCheckedContinuation { reachedWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}
