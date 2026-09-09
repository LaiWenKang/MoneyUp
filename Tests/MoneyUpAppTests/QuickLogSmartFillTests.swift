import Foundation
import MoneyUpCore
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
