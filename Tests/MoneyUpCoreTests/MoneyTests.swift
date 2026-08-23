import Foundation
@testable import MoneyUpCore
import XCTest

final class MoneyTests: XCTestCase {
    func testCurrencyCodeNormalizesCaseAndWhitespace() throws {
        let code = try CurrencyCode("  sgd\n")
        XCTAssertEqual(code.value, "SGD")
    }

    func testCurrencyCodeSupportsLongerDigitalAssetCodes() throws {
        XCTAssertEqual(try CurrencyCode("usdt").value, "USDT")
    }

    func testCurrencyCodeRejectsSymbolsAndUnsupportedLength() {
        XCTAssertThrowsError(try CurrencyCode("US$"))
        XCTAssertThrowsError(try CurrencyCode("SG"))
        XCTAssertThrowsError(try CurrencyCode("TOO-LONG-CODE"))
    }

    func testMoneyAddsExactDecimalValues() throws {
        let sgd = try CurrencyCode("SGD")
        let first = try Money(Decimal(string: "0.1")!, currency: sgd)
        let second = try Money(Decimal(string: "0.2")!, currency: sgd)

        let total = try first.adding(second)

        XCTAssertEqual(total.amount, Decimal(string: "0.3")!)
        XCTAssertEqual(total.currency, sgd)
    }

    func testMoneyRejectsCrossCurrencyArithmetic() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let local = try Money(10, currency: sgd)
        let foreign = try Money(10, currency: usd)

        XCTAssertThrowsError(try local.adding(foreign)) { error in
            XCTAssertEqual(
                error as? MoneyError,
                .currencyMismatch(expected: sgd, actual: usd)
            )
        }
    }
}
