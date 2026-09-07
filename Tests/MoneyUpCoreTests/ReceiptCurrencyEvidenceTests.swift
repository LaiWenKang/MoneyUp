import Foundation
import MoneyUpCore
import XCTest

final class ReceiptCurrencyEvidenceTests: XCTestCase {
    func testExplicitReceiptCurrencyCannotBeReinterpretedAsSelectedAccountCurrency() throws {
        let result = ReceiptTextParser.analyze(fromLines: ["PAYMENT SUCCESSFUL", "Amount paid USD 12.34", "Paid to: HARBOUR CAFE"])
        let usd = try CurrencyCode("USD"), sgd = try CurrencyCode("SGD")
        XCTAssertEqual(result.draft.amount, Decimal(string: "12.34"))
        XCTAssertEqual(result.currencyEvidence.identifiedCurrency, usd)
        XCTAssertFalse(result.currencyEvidence.permitsAutomaticFill(in: sgd))
        XCTAssertFalse(result.currencyEvidence.permitsExplicitUse(in: sgd))
        XCTAssertTrue(result.currencyEvidence.permitsAutomaticFill(in: usd))
    }

    func testAmbiguousSymbolsRequireCurrencyReviewWithoutChoosingACountry() throws {
        for text in ["Total $12.34", "实付 ¥23.45", "Total ￥23.45"] {
            let evidence = ReceiptTextParser.analyze(fromLines: [text]).currencyEvidence
            XCTAssertNil(evidence.identifiedCurrency)
            XCTAssertFalse(evidence.permitsAutomaticFill(in: try CurrencyCode("SGD")))
            XCTAssertTrue(evidence.permitsExplicitUse(in: try CurrencyCode("SGD")))
        }
    }

    func testAliasesSeparateCurrencyFromNoiseAndMixedCurrencyDocuments() throws {
        for (text, code) in [("TOTAL S$ 12.34", "SGD"), ("实付 RMB 23.45", "CNY"),
                             ("TOTAL RM 12.34", "MYR"), ("TOTAL US$ 12.34", "USD"),
                             ("TOTAL 23.45 EUR", "EUR"), ("Currency: KWD", "KWD")] {
            let evidence = ReceiptTextParser.analyze(fromLines: [text]).currencyEvidence
            XCTAssertEqual(evidence.identifiedCurrency, try CurrencyCode(code))
        }
        let mixed = ReceiptTextParser.analyze(fromLines: ["Amount paid USD 12.34", "Account charged SGD 16.50"]).currencyEvidence
        XCTAssertEqual(mixed.codes.map(\.value), ["SGD", "USD"])
        XCTAssertFalse(mixed.permitsAutomaticFill(in: try CurrencyCode("USD")))
        XCTAssertFalse(mixed.permitsExplicitUse(in: try CurrencyCode("SGD")))
        XCTAssertTrue(ReceiptTextParser.analyze(fromLines: ["ALL ITEMS", "TOTAL 12.34"]).currencyEvidence.codes.isEmpty)
    }

    func testAmountWithoutCurrencyKeepsExistingExplicitAccountContextAndNeverInventsCode() throws {
        let evidence = ReceiptTextParser.analyze(fromLines: ["TOTAL 12.34"]).currencyEvidence
        XCTAssertTrue(evidence.codes.isEmpty)
        XCTAssertTrue(evidence.permitsAutomaticFill(in: try CurrencyCode("SGD")))
        XCTAssertFalse(evidence.permitsAutomaticFill(in: nil))
    }
}
