import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class QuickLogSmartFillTests: XCTestCase {
    private func draft(_ phrase: String = "") -> QuickLogDraft {
        QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "",
            accountID: nil, destinationAccountID: nil, categoryID: nil,
            occurredAt: Date(timeIntervalSince1970: 1_000), dateWasEdited: false,
            payee: "", note: "", smartText: phrase)
    }

    func testFillUnderstandsNotesAndKeepsPhraseAndCaptureIdentity() throws {
        let currency = try CurrencyCode("SGD")
        let account = LedgerAccount(name: "Cash", kind: .asset, currency: currency)
        let category = LedgerAccount(name: "Food", kind: .expense)
        var current = draft("lunch SGD 12.50 Cash Food yesterday; with Sam")
        current.sourceCaptureID = UUID()
        let parsed = NaturalLanguageEntryParser.parse(current.smartText, accounts: [account, category])
        let result = QuickLogSmartFill(parsed: parsed, current: current, accounts: [account, category])
        XCTAssertEqual(decimalAmount(from: result.draft.amountText), Decimal(string: "12.50"))
        XCTAssertEqual(result.draft.payee, "lunch")
        XCTAssertEqual(result.draft.note, "with Sam")
        XCTAssertEqual(result.draft.accountID, account.id)
        XCTAssertEqual(result.draft.categoryID, category.id)
        XCTAssertEqual(result.draft.smartText, current.smartText)
        XCTAssertEqual(result.draft.sourceCaptureID, current.sourceCaptureID)
        XCTAssertEqual(result.messageKeys, ["quick_log.smart_review"])
    }

    func testManualMoneyDateTitleDescriptionAndSplitChoicesWin() throws {
        let account = LedgerAccount(name: "Cash", kind: .asset, currency: try CurrencyCode("SGD"))
        let other = LedgerAccount(name: "Card", kind: .asset, currency: try CurrencyCode("USD"))
        var current = draft("salary Card USD 5000 tomorrow; replacement")
        current.amountText = "12.00"
        current.accountID = account.id
        current.accountWasEdited = true
        current.categoryWasEdited = true
        current.categoryID = UUID()
        current.dateWasEdited = true
        current.payee = "My title"
        current.note = "My description"
        current.splitLines = [QuickLogSplitDraftLine(categoryID: current.categoryID, amountText: "12.00")]
        let parsed = NaturalLanguageEntryParser.parse(current.smartText, accounts: [account, other])
        let result = QuickLogSmartFill(parsed: parsed, current: current, accounts: [account, other])
        XCTAssertEqual(result.draft, current)
        XCTAssertTrue(result.messageKeys.contains("quick_log.smart_kind_review"))
        XCTAssertTrue(result.messageKeys.contains("quick_log.smart_currency_review"))
    }

    func testForeignCurrencyAndAmbiguousNumbersCannotPrefillMoney() throws {
        let account = LedgerAccount(name: "Cash", kind: .asset, currency: try CurrencyCode("SGD"))
        let foreign = LedgerAccount(name: "USD Wallet", kind: .asset, currency: try CurrencyCode("USD"))
        for phrase in ["lunch USD 12", "lunch USD Wallet 12", "lunch $12", "2 coffees 8.40", "lunch on 2026-02-31"] {
            var current = draft(phrase)
            current.accountID = account.id
            current.accountWasEdited = true
            let parsed = NaturalLanguageEntryParser.parse(phrase, accounts: [account, foreign])
            let result = QuickLogSmartFill(parsed: parsed, current: current, accounts: [account, foreign])
            XCTAssertTrue(result.draft.amountText.isEmpty, phrase)
            XCTAssertNotEqual(result.messageKeys, ["quick_log.smart_review"], phrase)
        }
    }

    func testTypedAmountNeverMovesToAnotherAccountThroughSmartFill() throws {
        let cash = LedgerAccount(name: "Cash", kind: .asset, currency: try CurrencyCode("SGD"))
        let other = LedgerAccount(name: "Card", kind: .asset, currency: try CurrencyCode("USD"))
        var current = draft("Card lunch 15")
        current.accountID = cash.id
        current.amountText = "12.00"
        let result = QuickLogSmartFill(
            parsed: NaturalLanguageEntryParser.parse(current.smartText, accounts: [cash, other]),
            current: current, accounts: [cash, other]
        )
        XCTAssertEqual(result.draft.accountID, cash.id)
        XCTAssertEqual(result.draft.amountText, "12.00")
        XCTAssertTrue(result.messageKeys.contains("quick_log.smart_currency_review"))
    }

    func testUnsupportedPrecisionIsNeverRoundedIntoTheForm() throws {
        let account = LedgerAccount(name: "Cash", kind: .asset, currency: try CurrencyCode("SGD"))
        for phrase in ["coffee 12.345", "coffee 12.00000000000000001", "coffee 9999999999999999"] {
            var current = draft(phrase)
            current.accountID = account.id
            let result = QuickLogSmartFill(
                parsed: NaturalLanguageEntryParser.parse(phrase, accounts: [account]),
                current: current, accounts: [account]
            )
            XCTAssertTrue(result.draft.amountText.isEmpty, phrase)
            XCTAssertTrue(result.messageKeys.contains("quick_log.smart_precision_review"), phrase)
        }
    }
}


final class HistoryPreloadIntegrationTests: XCTestCase {
    @MainActor
    func testReadsPersistedHistoryWithoutMutatingDraftAndRespectsOptOut() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = try [100.0, 200].map {
            try TransactionFactory.expense(amount: Money(7, currency: fixture.sgd),
                paidFrom: fixture.wallet.id, category: fixture.food.id,
                occurredAt: now.addingTimeInterval(-$0), payee: "Coffee")
        }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: entries)
        let model = fixture.model(profile: profile, retainsCompleteJournal: false)
        let query = CaptureSuggestionQuery(kind: .expense, currency: fixture.sgd, occurredAt: now)
        let before = model.quickLogDraft
        let result = await model.historyPreloadSuggestions(for: query, eligibleCategoryIDs: [fixture.food.id])
        XCTAssertEqual(result.merchants.map(\.payee), ["Coffee"])
        XCTAssertEqual(result.fields.categorySuggestion?.ledgerAccountID, fixture.food.id)
        XCTAssertEqual(model.quickLogDraft, before)
        XCTAssertTrue(model.entries.isEmpty)
        model.profile?.merchantSuggestionsEnabled = false
        let disabled = await model.historyPreloadSuggestions(for: query, eligibleCategoryIDs: [fixture.food.id])
        XCTAssertTrue(disabled.merchants.isEmpty)
        XCTAssertNil(disabled.fields.categorySuggestion)
        await fixture.store.close()
    }
}

final class HistoryPreloadFillTests: XCTestCase {
    private func fixture() throws -> (HistoryPreloadSuggestion, QuickLogDraft, [LedgerAccount]) {
        let currency = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: currency)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = try [100.0, 200].map {
            try TransactionFactory.expense(amount: Money(7, currency: currency), paidFrom: bank.id,
                category: food.id, occurredAt: now.addingTimeInterval(-$0), payee: "Cafe")
        }
        let suggestion = try XCTUnwrap(HistoryPreload.suggestions(for:
            CaptureSuggestionQuery(kind: .expense, currency: currency, occurredAt: now),
            entries: entries, accounts: [bank, food], calendar: Calendar(identifier: .gregorian)).first)
        let draft = QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "",
            accountID: bank.id, destinationAccountID: nil, categoryID: food.id, occurredAt: now,
            dateWasEdited: false, payee: "", note: "Keep this note", smartText: "")
        return (suggestion, draft, [bank, food])
    }

    func testApplyAllFillsFourFieldsAndPreservesDateNoteAndDraftIdentity() throws {
        let (suggestion, draft, accounts) = try fixture()
        let result = QuickLogHistoryPreloadFill.fill(suggestion, current: draft, accounts: accounts)
        XCTAssertEqual(result.payee, "Cafe")
        XCTAssertEqual(decimalAmount(from: result.amountText), 7)
        XCTAssertEqual(result.accountID, accounts[0].id)
        XCTAssertEqual(result.categoryID, accounts[1].id)
        XCTAssertEqual(result.occurredAt, draft.occurredAt)
        XCTAssertEqual(result.note, draft.note)
        XCTAssertEqual(result.smartState.manualFields, [.payee, .amount, .account, .category])
        XCTAssertEqual(result, QuickLogHistoryPreloadFill.fill(suggestion, current: result, accounts: accounts))
    }

    func testEveryEditedFieldIncludingClearedValuesSurvivesRestoreAndEveryArrow() throws {
        let (suggestion, draft, accounts) = try fixture()
        var current = draft
        current.smartState.manualFields = QuickLogHistoryPreloadFill.fields
        current.accountWasEdited = true
        current.categoryWasEdited = true
        current = try JSONDecoder().decode(QuickLogDraft.self, from: JSONEncoder().encode(current))
        for fields in QuickLogHistoryPreloadFill.fields.map({ Set([$0]) }) + [QuickLogHistoryPreloadFill.fields] {
            XCTAssertEqual(QuickLogHistoryPreloadFill.fill(suggestion, current: current,
                accounts: accounts, only: fields), current)
        }
        current.amountText = "123.45"
        current.payee = "My own name"
        XCTAssertEqual(QuickLogHistoryPreloadFill.fill(suggestion, current: current, accounts: accounts), current)
    }

    func testIndividualArrowNeverChangesOtherFieldsAndRejectsInvalidContext() throws {
        let (suggestion, draft, accounts) = try fixture()
        let result = QuickLogHistoryPreloadFill.fill(suggestion, current: draft, accounts: accounts, only: [.amount])
        XCTAssertEqual(decimalAmount(from: result.amountText), 7)
        XCTAssertEqual(result.payee, draft.payee)
        XCTAssertEqual(result.accountID, draft.accountID)
        XCTAssertEqual(result.categoryID, draft.categoryID)
        XCTAssertFalse(result.accountWasEdited)
        XCTAssertFalse(result.categoryWasEdited)
        var split = draft
        split.splitLines = [QuickLogSplitDraftLine(categoryID: accounts[1].id, amountText: "7")]
        XCTAssertEqual(QuickLogHistoryPreloadFill.fill(suggestion, current: split, accounts: accounts), split)
        var refund = draft
        refund.kind = .refund
        XCTAssertEqual(QuickLogHistoryPreloadFill.fill(suggestion, current: refund, accounts: accounts), refund)
        XCTAssertEqual(QuickLogHistoryPreloadFill.fill(suggestion, current: draft, accounts: []), draft)
        let foreign = LedgerAccount(name: "Foreign", kind: .asset, currency: try CurrencyCode("USD"))
        var foreignDraft = draft
        foreignDraft.accountID = foreign.id
        foreignDraft.accountWasEdited = true
        XCTAssertEqual(QuickLogHistoryPreloadFill.fill(suggestion, current: foreignDraft,
            accounts: accounts + [foreign]), foreignDraft)
    }
}

extension HistoryPreloadFillTests {
    func testPartialNameAndParserFieldsRemainUntouched() throws {
        let (suggestion, draft, accounts) = try fixture()
        var current = draft
        current.payee = "Ca"
        current.smartState.edited(.payee)
        let result = QuickLogHistoryPreloadFill.fill(suggestion, current: current, accounts: accounts)
        XCTAssertEqual(result.payee, "Ca")
        XCTAssertEqual(decimalAmount(from: result.amountText), 7)
        current.smartState.automaticFields = [.amount, .account, .category]
        XCTAssertEqual(QuickLogHistoryPreloadFill.fill(suggestion, current: current, accounts: accounts), current)
    }
}

extension HistoryPreloadFillTests {
    func testEditedBankNeverReceivesAnotherBanksAmountOrCategory() throws {
        let (suggestion, draft, accounts) = try fixture()
        let otherBank = LedgerAccount(name: "Other bank", kind: .asset, currency: accounts[0].currency)
        let otherCategory = LedgerAccount(name: "Other category", kind: .expense)
        var current = draft
        current.accountID = otherBank.id
        current.accountWasEdited = true
        current.categoryID = otherCategory.id
        let result = QuickLogHistoryPreloadFill.fill(suggestion, current: current,
            accounts: accounts + [otherBank, otherCategory])
        XCTAssertEqual(result.accountID, otherBank.id)
        XCTAssertEqual(result.categoryID, otherCategory.id)
        XCTAssertEqual(result.amountText, "")
        XCTAssertEqual(result.payee, "Cafe")
    }
}
