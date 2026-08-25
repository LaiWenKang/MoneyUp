import Foundation
@testable import MoneyUpCore
import XCTest

final class MoneyTests: XCTestCase {
    func testLegacyUserProfileDefaultsToOneMinuteAutoLock() throws {
        let legacy = Data(
            """
            {"baseCurrency":"SGD","createdAt":0,"lockWhenBackgrounded":true}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(UserProfile.self, from: legacy)

        XCTAssertEqual(decoded.autoLockDelay, 60)
        XCTAssertTrue(decoded.allowLockedQuickCapture)
        XCTAssertNil(decoded.preferredAccountID)
    }

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

    func testCurrencyMinorUnitsRejectUnsupportedPrecisionWithoutChangingLegacyMoney() throws {
        let jpy = try CurrencyCode("JPY")
        let kwd = try CurrencyCode("KWD")
        let sgd = try CurrencyCode("SGD")

        XCTAssertTrue(jpy.supports(Decimal(125)))
        XCTAssertFalse(jpy.supports(Decimal(string: "125.5")!))
        XCTAssertTrue(kwd.supports(Decimal(string: "1.234")!))
        XCTAssertFalse(kwd.supports(Decimal(string: "1.2345")!))
        XCTAssertEqual(sgd.rounded(Decimal(string: "1.005")!), Decimal(string: "1.00")!)

        // Existing decoded values are preserved exactly. Input boundaries, not
        // Money decoding, enforce the new rule so an update cannot mutate data.
        XCTAssertEqual(
            try Money(Decimal(string: "12.345")!, currency: sgd).amount,
            Decimal(string: "12.345")!
        )
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
