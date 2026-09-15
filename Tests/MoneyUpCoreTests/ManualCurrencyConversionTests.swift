import Foundation
import MoneyUpCore
import XCTest

final class ManualCurrencyConversionTests: XCTestCase {
    func testExactRateAndDestinationPrecision() throws {
        let source = try Money(100, currency: CurrencyCode("SGD"))
        let rate = try XCTUnwrap(Decimal(string: "3.456789"))
        XCTAssertEqual(try ManualCurrencyConversion.convert(source: source,
            to: CurrencyCode("MYR"), rate: rate).amount, Decimal(string: "345.68"))
        XCTAssertEqual(try ManualCurrencyConversion.convert(source: source,
            to: CurrencyCode("JPY"), rate: rate).amount, 346)
        XCTAssertEqual(try ManualCurrencyConversion.convert(source: source,
            to: CurrencyCode("KWD"), rate: rate).amount, Decimal(string: "345.679"))
    }

    func testReverseRateDividesWithoutRoundingReciprocalFirst() throws {
        let source = try Money(100, currency: CurrencyCode("SGD"))
        let rate = try XCTUnwrap(Decimal(string: "0.009"))
        XCTAssertEqual(try ManualCurrencyConversion.convert(source: source,
            to: CurrencyCode("JPY"), rate: rate, inverse: true).amount, 11_111)
        XCTAssertThrowsError(try ManualCurrencyConversion.convert(source: source,
            to: CurrencyCode("JPY"), rate: .zero, inverse: true))
    }

    func testRejectsInvalidRatesAndUnrepresentableAmounts() throws {
        let source = try Money(100, currency: CurrencyCode("SGD"))
        for rate in [Decimal.zero, -1, .nan, Decimal(string: "1e-100")!, Decimal(string: "9e127")!] {
            XCTAssertThrowsError(try ManualCurrencyConversion.convert(source: source,
                to: CurrencyCode("MYR"), rate: rate))
        }
        XCTAssertThrowsError(try ManualCurrencyConversion.convert(source: source,
            to: source.currency, rate: 1))
    }
}
