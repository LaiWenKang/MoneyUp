import Foundation
@testable import MoneyUpCore
import XCTest

final class MoneyCurrencyDisplayTests: XCTestCase {
    private func currencies(_ codes: String...) throws -> [CurrencyCode] {
        try codes.map { try CurrencyCode($0) }
    }

    func testCurrenciesSharingOneSymbolAreAllAmbiguous() throws {
        let codes = try currencies("SGD", "USD", "MYR", "JPY")
        let ambiguous = MoneyCurrencyAmbiguity.ambiguousCurrencies(
            symbolsByCurrency: [
                codes[0]: "$",
                codes[1]: "$",
                codes[2]: "RM",
                codes[3]: "¥"
            ]
        )

        XCTAssertEqual(ambiguous, Set([codes[0], codes[1]]))
    }

    func testSingleCurrencyBookKeepsItsSymbolEvenWhenTheSymbolIsShareable() throws {
        let usd = try CurrencyCode("USD")

        XCTAssertTrue(
            MoneyCurrencyAmbiguity.ambiguousCurrencies(
                symbolsByCurrency: [usd: "$"]
            ).isEmpty
        )
    }

    func testSelfIdentifyingSymbolsNeverCollideAndBlankSymbolsAlwaysDo() throws {
        let codes = try currencies("SGD", "USD", "BTC")
        // A symbol that already is the ISO code identifies its own currency,
        // so two such currencies must not be reported as colliding.
        XCTAssertTrue(
            MoneyCurrencyAmbiguity.ambiguousCurrencies(
                symbolsByCurrency: [codes[0]: "SGD", codes[1]: "USD"]
            ).isEmpty
        )
        // A symbol Foundation cannot supply identifies nothing at all.
        XCTAssertEqual(
            MoneyCurrencyAmbiguity.ambiguousCurrencies(
                symbolsByCurrency: [codes[2]: "  ", codes[1]: "$"]
            ),
            Set([codes[2]])
        )
    }

    func testAutomaticNotationFollowsAmbiguityAndExplicitChoicesOverrideIt() throws {
        let codes = try currencies("SGD", "MYR")
        let ambiguous = Set([codes[0]])

        XCTAssertEqual(
            MoneyCurrencyAmbiguity.notation(
                for: codes[0],
                preference: .automatic,
                ambiguousCurrencies: ambiguous
            ),
            .code
        )
        XCTAssertEqual(
            MoneyCurrencyAmbiguity.notation(
                for: codes[1],
                preference: .automatic,
                ambiguousCurrencies: ambiguous
            ),
            .symbol
        )
        XCTAssertEqual(
            MoneyCurrencyAmbiguity.notation(
                for: codes[0],
                preference: .symbol,
                ambiguousCurrencies: ambiguous
            ),
            .symbol
        )
        XCTAssertEqual(
            MoneyCurrencyAmbiguity.notation(
                for: codes[1],
                preference: .code,
                ambiguousCurrencies: ambiguous
            ),
            .code
        )
    }
}
