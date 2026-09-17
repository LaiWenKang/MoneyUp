import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class EntryCatalogTests: XCTestCase {
    @MainActor
    func testAccountPresetIsOptInZeroBalanceAndIdempotentAcrossCurrencies() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let original = [fixture.wallet, fixture.food]
        try await fixture.seed(profile: profile, accounts: original)
        let model = fixture.model(profile: profile, accounts: original)
        XCTAssertEqual(model.accounts, original)
        XCTAssertTrue(model.accounts.allSatisfy { $0.presetID == nil && !$0.isHiddenFromEntry })
        try await model.setEntryPresetEnabled("account.cash", enabled: false, currencyCode: "SGD")
        XCTAssertEqual(model.accounts, original)
        try await model.setEntryPresetEnabled("account.cash", enabled: true, currencyCode: "SGD")
        let cash = try XCTUnwrap(model.accounts.first { $0.presetID == "account.cash" })
        try await model.setEntryPresetEnabled("account.cash", enabled: true, currencyCode: "SGD")
        XCTAssertEqual(model.accounts.filter { $0.presetID == "account.cash" }.map(\.id), [cash.id])
        try await model.setEntryPresetEnabled("account.cash", enabled: true, currencyCode: "USD")
        XCTAssertEqual(Set(model.accounts.filter { $0.presetID == "account.cash" }.compactMap(\.currency)), [fixture.sgd, fixture.usd])
        let entries = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertTrue(entries.isEmpty, "Enabling presets must never create money or opening postings")
        await fixture.store.close()
    }

    @MainActor
    func testCreditAndLoanPresetsAreLiabilitiesAndRetirementIsNotSpendableCash() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        for id in ["account.credit_card", "account.mortgage", "account.retirement"] {
            try await model.setEntryPresetEnabled(id, enabled: true, currencyCode: "SGD")
        }
        XCTAssertTrue(model.accounts.filter { $0.presetID.map { ["account.credit_card", "account.mortgage"].contains($0) } ?? false }.allSatisfy { $0.kind == .liability })
        let retirement = try XCTUnwrap(model.accounts.first { $0.presetID == "account.retirement" })
        XCTAssertEqual(retirement.accountType, .investment)
        XCTAssertFalse(retirement.accountType!.isUnrestrictedLiquidity)
        XCTAssertTrue(model.entries.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testCategoryOffPreservesBudgetsHistoryDraftAndIdentityAcrossReenable() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food])
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food])
        try await model.setEntryPresetEnabled("expense.dining", enabled: true, currencyCode: "SGD")
        let category = try XCTUnwrap(model.accounts.first { $0.presetID == "expense.dining" })
        let draft = QuickLogDraft(kind: .expense, amountText: "5", destinationAmountText: "",
            accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: category.id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000), dateWasEdited: false,
            payee: "Unfinished", note: "Keep this draft", smartText: "")
        model.updateQuickLogDraft(draft)
        model.flushQuickLogDraftImmediately()
        await model.waitForPendingQuickLogDraftFlush()
        let nodes = model.budgetNodes
        let timeline = model.budgetConfigurationTimeline
        XCTAssertNil(nodes.first { $0.id == category.id }?.limit)
        XCTAssertNotNil(nodes.first { $0.id == category.id })
        try await model.setEntryPresetEnabled("expense.dining", enabled: false, currencyCode: "SGD")
        XCTAssertEqual(model.budgetNodes, nodes)
        XCTAssertEqual(model.quickLogDraft, draft)
        XCTAssertEqual(model.budgetConfigurationTimeline, timeline)
        XCTAssertTrue(model.accountsByID[category.id]!.isHiddenFromEntry)
        XCTAssertFalse(model.accountsByID[category.id]!.isArchived)
        XCTAssertTrue(model.expenseCategories.contains { $0.id == category.id })
        XCTAssertFalse(LedgerEntryChoices.visible(model.expenseCategories).contains { $0.id == category.id })
        let persisted = try await fixture.store.fetch(LedgerAccount.self, id: category.id.uuidString, from: .accounts)
        XCTAssertEqual(persisted, model.accountsByID[category.id])
        try await model.setEntryPresetEnabled("expense.dining", enabled: true, currencyCode: "SGD")
        XCTAssertEqual(model.accounts.filter { $0.presetID == "expense.dining" }.map(\.id), [category.id])
        XCTAssertEqual(model.budgetNodes, nodes)
        XCTAssertTrue(model.entries.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testHidingAnExistingAccountPreservesItsJournalAndBalanceMembership() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 12)
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: [entry])
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food], entries: [entry])
        let originalWorth = try XCTUnwrap(model.netWorthByCurrencyResult().value)
        try await model.setEntryOptionEnabled(id: fixture.wallet.id, enabled: false)
        XCTAssertEqual(try XCTUnwrap(model.netWorthByCurrencyResult().value), originalWorth)
        XCTAssertEqual(model.entries, [entry])
        XCTAssertTrue(model.allUserAccounts.contains { $0.id == fixture.wallet.id })
        XCTAssertTrue(model.userAccounts.contains { $0.id == fixture.wallet.id })
        XCTAssertTrue(LedgerEntryChoices.visible(model.userAccounts).isEmpty)
        XCTAssertEqual(LedgerEntryChoices.visible(model.userAccounts, preserving: [fixture.wallet.id]).map(\.id), [fixture.wallet.id])
        let entries = try await fixture.store.fetchAll(JournalEntry.self, from: .journalEntries)
        XCTAssertEqual(entries, [entry])
        await fixture.store.close()
    }

    @MainActor
    func testHiddenAccountCannotReturnAsAnUnselectedHistoryPreload() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = try [60.0, 120.0].map {
            try TransactionFactory.expense(amount: Money(7, currency: fixture.sgd),
                paidFrom: fixture.wallet.id, category: fixture.food.id,
                occurredAt: now.addingTimeInterval(-$0), payee: "Coffee")
        }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: entries)
        let model = fixture.model(profile: profile, accounts: [fixture.wallet, fixture.food], entries: entries)
        try await model.setEntryOptionEnabled(id: fixture.wallet.id, enabled: false)
        let query = CaptureSuggestionQuery(kind: .expense, currency: fixture.sgd, occurredAt: now)
        let result = await model.historyPreloadSuggestions(for: query, eligibleCategoryIDs: [fixture.food.id])
        XCTAssertTrue(result.merchants.isEmpty)
        XCTAssertNil(result.fields.accountSuggestion)
        let retained = await model.historyPreloadSuggestions(for: query,
            eligibleCategoryIDs: [fixture.food.id], accountID: fixture.wallet.id)
        XCTAssertFalse(retained.merchants.isEmpty, "An explicitly retained draft account remains usable")
        await fixture.store.close()
    }

    @MainActor
    func testFailedPresetWriteDoesNotPublishAnAccountOrBudget() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let original = model.accounts
        let originalBudgets = model.budgetNodes
        await fixture.store.close()
        do {
            try await model.setEntryPresetEnabled("expense.dining", enabled: true, currencyCode: "SGD")
            XCTFail("Closed storage must reject the write")
        } catch {}
        XCTAssertEqual(model.accounts, original)
        XCTAssertEqual(model.budgetNodes, originalBudgets)
        XCTAssertFalse(model.isJournalMutationInProgress)
    }
}
