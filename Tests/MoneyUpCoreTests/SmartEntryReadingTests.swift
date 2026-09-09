import Foundation
@testable import MoneyUpCore
import XCTest

final class SmartEntryReadingTests: XCTestCase {
    private let locale = Locale(identifier: "en_SG")

    func testNumberBearingAccountAndCategoryNamesAreNotAmounts() {
        let card = LedgerAccount(name: "Card 1234", kind: .liability, accountType: .creditCard)
        let category = LedgerAccount(name: "Food 2026", kind: .expense)
        let parsed = NaturalLanguageEntryParser.parse(
            "Card 1234 Food 2026 lunch 12.50", accounts: [card, category], locale: locale
        )
        XCTAssertEqual(parsed.draft.accountID, card.id)
        XCTAssertEqual(parsed.draft.categoryID, category.id)
        XCTAssertEqual(parsed.draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(parsed.draft.payee, "lunch")
        XCTAssertFalse(parsed.needsAmountReview)
    }

    func testQuantityNeedsReviewUnlessOneTotalIsExplicit() {
        for phrase in ["2 coffees 8.40", "lunch 12 dinner 18", "coffee 4 4"] {
            let result = NaturalLanguageEntryParser.parse(phrase, accounts: [], locale: locale)
            XCTAssertNil(result.draft.amount, phrase)
            XCTAssertTrue(result.needsAmountReview, phrase)
        }
        for phrase in ["2 coffees total 8.40", "2杯咖啡 合计：8.40", "２杯咖啡 總計８.４０"] {
            let result = NaturalLanguageEntryParser.parse(phrase, accounts: [], locale: locale)
            XCTAssertEqual(result.draft.amount, Decimal(string: "8.40"), phrase)
            XCTAssertFalse(result.needsAmountReview, phrase)
        }
    }

    func testNotesCannotChangeFinancialFieldsOrAssistanceContext() {
        for separator in [";", "；"] {
            let result = NaturalLanguageEntryParser.parse(
                "lunch 12.50\(separator) refund USD 99 tomorrow; table 8", accounts: [], locale: locale
            )
            XCTAssertEqual(result.draft.kind, .expense)
            XCTAssertEqual(result.draft.amount, Decimal(string: "12.50"))
            XCTAssertNil(result.draft.occurredAt)
            XCTAssertEqual(result.draft.payee, "lunch")
            XCTAssertEqual(result.note, "refund USD 99 tomorrow; table 8")
            XCTAssertEqual(result.context, "lunch")
            XCTAssertTrue(result.currencyEvidence.codes.isEmpty)
        }
    }

    func testFullwidthInputAndExplicitCurrencyStayExact() throws {
        let parsed = NaturalLanguageEntryParser.parse("午餐 ＳＧＤ１２.５０；和朋友", accounts: [], locale: locale)
        XCTAssertEqual(parsed.draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(parsed.currencyEvidence.identifiedCurrency, try CurrencyCode("SGD"))
        XCTAssertEqual(parsed.note, "和朋友")
        XCTAssertFalse(parsed.currencyEvidence.permitsAutomaticFill(in: try CurrencyCode("USD")))
        let ambiguous = NaturalLanguageEntryParser.parse("lunch $12", accounts: [], locale: locale)
        XCTAssertTrue(ambiguous.currencyEvidence.hasAmbiguousSymbol)
        XCTAssertFalse(ambiguous.currencyEvidence.permitsAutomaticFill(in: try CurrencyCode("SGD")))
        let english = NaturalLanguageEntryParser.parse("lunch 12 US dollars", accounts: [], locale: locale)
        XCTAssertEqual(english.currencyEvidence.identifiedCurrency, try CurrencyCode("USD"))
        XCTAssertEqual(english.draft.amount, 12)
        XCTAssertEqual(english.draft.payee, "lunch")
        let unspecified = NaturalLanguageEntryParser.parse("lunch 12 dollars", accounts: [], locale: locale)
        XCTAssertTrue(unspecified.currencyEvidence.hasAmbiguousSymbol)
    }

    func testMalformedSignedAndAmbiguousTotalsDoNotBecomePositiveAmounts() {
        for phrase in ["coffee -12", "coffee +12", "coffee 12,3", "total 8 total 9", "coffee 0",
                       "coffee 12.00000000000000000000000000000000000000000001"] {
            let result = NaturalLanguageEntryParser.parse(phrase, accounts: [], locale: locale)
            XCTAssertNil(result.draft.amount, phrase)
            XCTAssertTrue(result.needsAmountReview, phrase)
        }
        let german = NaturalLanguageEntryParser.parse(
            "2 Kaffee total 1.234,50", accounts: [], locale: Locale(identifier: "de_DE")
        )
        XCTAssertEqual(german.draft.amount, Decimal(string: "1234.50"))
    }

    func testMerchantDigitsAndDatesCannotStealTheAmount() {
        let result = NaturalLanguageEntryParser.parse(
            "7-Eleven H2O 12.50 on 2026-09-08", accounts: [], locale: locale
        )
        XCTAssertEqual(result.draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(result.draft.payee, "7-Eleven H2O")
        let invalid = NaturalLanguageEntryParser.parse("lunch 12 on 2026-02-31", accounts: [], locale: locale)
        XCTAssertNil(invalid.draft.amount)
        XCTAssertTrue(invalid.needsDateReview)
    }
}
