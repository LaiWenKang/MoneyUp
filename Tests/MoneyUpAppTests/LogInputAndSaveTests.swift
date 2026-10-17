import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

/// Log, round 4: an amount written with one possible reading is read, and an
/// ambiguous one is still refused; a dimmed Save always has words for why.
/// Fictional data only.
final class LogInputAndSaveTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    /// A pasted "1,234.50" or a typed ".5" used to say "Enter a valid amount."
    func testAmountsWithOneReadingAreReadExactly() throws {
        func written(_ text: String, _ locale: Locale) -> WrittenAmount? { writtenAmount(from: text, locale: locale) }
        func exact(_ text: String) throws -> Decimal { try XCTUnwrap(Decimal(string: text)) }
        let fr = Locale(identifier: "fr_FR")
        let swiss = Locale(identifier: "de_CH")
        let swissGroup = try XCTUnwrap(swiss.groupingSeparator)

        XCTAssertEqual(written("1,234.50", us), WrittenAmount(value: try exact("1234.5"), fractionDigits: 2))
        XCTAssertEqual(written("1,234,567", us), WrittenAmount(value: 1_234_567, fractionDigits: 0))
        XCTAssertEqual(written("12,345.6", us), WrittenAmount(value: try exact("12345.6"), fractionDigits: 1))
        XCTAssertEqual(written(".5", us), WrittenAmount(value: try exact("0.5"), fractionDigits: 1))
        XCTAssertEqual(written("-.25", us), WrittenAmount(value: try exact("-0.25"), fractionDigits: 2))
        XCTAssertEqual(written("1.234,50", de), WrittenAmount(value: try exact("1234.5"), fractionDigits: 2))
        XCTAssertEqual(written("1.234.567", de), WrittenAmount(value: 1_234_567, fractionDigits: 0))
        XCTAssertEqual(written(",5", de), WrittenAmount(value: try exact("0.5"), fractionDigits: 1))
        XCTAssertEqual(written("1 234,50", fr)?.value, try exact("1234.5"), "A typed space groups like the locale's own")
        XCTAssertEqual(written("1\u{202F}234,50", fr)?.value, try exact("1234.5"))
        XCTAssertEqual(written("1\(swissGroup)234.50", swiss)?.value, try exact("1234.5"))

        // The currency's scale still decides, after the grouping is read.
        let usd = try CurrencyCode("USD")
        let kwd = try CurrencyCode("KWD")
        XCTAssertNil(moneyAmount(from: "1,234.567", currency: usd, locale: us))
        XCTAssertEqual(moneyAmount(from: "1,234.567", currency: kwd, locale: us), try exact("1234.567"))
        XCTAssertNil(MoneyInputIssue.of("1,234.50", currency: usd, locale: us))
        XCTAssertNil(MoneyInputIssue.of(".5", currency: usd, locale: us))
        XCTAssertEqual(MoneyInputIssue.of("1,234.567", currency: usd, locale: us), .precision(usd))
        XCTAssertNil(MoneyInputIssue.of(".", currency: usd, isEditing: true, locale: us), "Typing has only begun")
        XCTAssertEqual(MoneyInputIssue.of(".", currency: usd, locale: us), .invalid)
    }

    /// M1 stays: text that could be a decimal in another convention is never
    /// guessed, and grouping that is not in threes is not grouping.
    func testAmbiguousOrMalformedGroupingIsStillRefused() throws {
        for text in ["1,234", "1,23.45", "12,34,567.50", "1,234.5.6", "1,,234.50", ",5", "1.234,50", "$1,234.50"] {
            XCTAssertNil(writtenAmount(from: text, locale: us), "en_US \(text)")
        }
        for text in ["1.234", "1.000", ".500", "1,234.50", "1.23,45"] {
            XCTAssertNil(writtenAmount(from: text, locale: de), "de_DE \(text)")
        }
        XCTAssertNil(moneyAmount(from: "25.000", currency: try CurrencyCode("IDR"), locale: Locale(identifier: "id_ID")))
        XCTAssertNil(moneyAmount(from: "50.000", currency: try CurrencyCode("VND"), locale: us))
        XCTAssertEqual(MoneyInputIssue.of("1,234", currency: try CurrencyCode("USD"), locale: us), .invalid)
    }

    /// Every reason a dimmed Save can give is worded in both languages.
    func testEveryDimmedSaveReasonHasWordsInBothLanguages() {
        let blockers: [QuickLogSaveBlocker] = [
            .busy, .smartEntry, .amount, .account, .category, .split, .allowance, .destination, .receivedAmount
        ]
        XCTAssertEqual(Set(blockers.map(\.messageKey)).count, blockers.count, "Each reason has its own words")
        for blocker in blockers {
            for language in [AppLanguagePreference.english, .simplifiedChinese] {
                let words = AppLocalization.string(blocker.messageKey, language: language)
                XCTAssertNotEqual(words, blocker.messageKey, "\(blocker) has no \(language) wording")
                XCTAssertFalse(words.isEmpty)
            }
        }
        XCTAssertEqual(
            AppLocalization.string(QuickLogSaveBlocker.amount.messageKey, language: .english),
            "Enter or confirm the amount."
        )
        XCTAssertEqual(
            AppLocalization.string(QuickLogSaveBlocker.destination.messageKey, language: .english),
            "Choose the receiving account."
        )
    }
}
