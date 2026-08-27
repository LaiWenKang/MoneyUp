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
        XCTAssertEqual(decoded.reportingTimeZoneIdentifier, "GMT")
    }

    func testRetiredBackgroundLockFlagIsIgnoredAndNotReencoded() throws {
        let legacy = Data(
            """
            {"baseCurrency":"SGD","createdAt":0,"lockWhenBackgrounded":false}
            """.utf8
        )

        let decoded = try JSONDecoder().decode(UserProfile.self, from: legacy)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNil(object["lockWhenBackgrounded"])
        XCTAssertEqual(decoded.autoLockDelay, 60)
    }

    func testProfileDecodePreservesValidLegacyDelayButRejectsInvalidPresentFields() throws {
        let legacyDelay = Data(
            """
            {"baseCurrency":"SGD","createdAt":0,"autoLockDelay":120}
            """.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(UserProfile.self, from: legacyDelay).autoLockDelay,
            120
        )

        let negativeDelay = Data(
            """
            {"baseCurrency":"SGD","createdAt":0,"autoLockDelay":-1}
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(UserProfile.self, from: negativeDelay)
        )

        let invalidTimeZone = Data(
            """
            {"baseCurrency":"SGD","createdAt":0,"reportingTimeZoneIdentifier":"Not/A_Zone"}
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(UserProfile.self, from: invalidTimeZone)
        )
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
        let btc = try CurrencyCode("BTC")

        XCTAssertTrue(jpy.supports(Decimal(125)))
        XCTAssertFalse(jpy.supports(Decimal(string: "125.5")!))
        XCTAssertTrue(kwd.supports(Decimal(string: "1.234")!))
        XCTAssertFalse(kwd.supports(Decimal(string: "1.2345")!))
        XCTAssertTrue(btc.supports(Decimal(string: "0.12345678")!))
        XCTAssertFalse(btc.supports(Decimal(string: "0.123456789")!))
        XCTAssertEqual(sgd.rounded(Decimal(string: "1.005")!), Decimal(string: "1.00")!)

        // Existing decoded values are preserved exactly. Input boundaries, not
        // Money decoding, enforce the new rule so an update cannot mutate data.
        XCTAssertEqual(
            try Money(Decimal(string: "12.345")!, currency: sgd).amount,
            Decimal(string: "12.345")!
        )
    }

    func testNewWritePolicyAcceptsHighDenominationBalancesAndCurrencyScales() throws {
        let vnd = try CurrencyCode("VND")
        let idr = try CurrencyCode("IDR")
        let jpy = try CurrencyCode("JPY")
        let kwd = try CurrencyCode("KWD")
        let btc = try CurrencyCode("BTC")

        XCTAssertNoThrow(try Money.newWrite(500_000_000, currency: vnd))
        XCTAssertNoThrow(try Money.newWrite(2_500_000_000, currency: idr))
        XCTAssertNoThrow(try Money.newWrite(-500_000_000, currency: vnd))
        XCTAssertNoThrow(
            try Money.newWrite(
                MonetaryInputPolicy.maximumAbsoluteNewWrite,
                currency: jpy
            )
        )
        XCTAssertNoThrow(
            try Money.newWrite(Decimal(string: "123.456")!, currency: kwd)
        )
        XCTAssertNoThrow(
            try Money.newWrite(Decimal(string: "0.12345678")!, currency: btc)
        )

        XCTAssertThrowsError(
            try Money.newWrite(Decimal(string: "1.5")!, currency: jpy)
        ) { error in
            XCTAssertEqual(
                error as? MoneyError,
                .unsupportedPrecision(currency: jpy)
            )
        }
        XCTAssertThrowsError(
            try Money.newWrite(Decimal(string: "1.2345")!, currency: kwd)
        )
        XCTAssertThrowsError(
            try Money.newWrite(Decimal(string: "0.123456789")!, currency: btc)
        )
    }

    func testNewWritePolicyRejectsAbsurdMagnitudeButPreservesLegacyExactly() throws {
        let sgd = try CurrencyCode("SGD")
        let absurd = try XCTUnwrap(
            Decimal(string: "999999999999999999999999999999.99")
        )
        XCTAssertThrowsError(try Money.newWrite(absurd, currency: sgd)) { error in
            XCTAssertEqual(
                error as? MoneyError,
                .exceedsNewWriteMaximum(
                    maximum: MonetaryInputPolicy.maximumAbsoluteNewWrite
                )
            )
        }
        XCTAssertThrowsError(try Money.newWrite(-absurd, currency: sgd))

        let legacyAmount = try XCTUnwrap(
            Decimal(string: "1000000000000000.12345")
        )
        let legacy = try Money(legacyAmount, currency: sgd)
        let roundTrip = try JSONDecoder().decode(
            Money.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(roundTrip.amount, legacyAmount)
        XCTAssertNoThrow(
            try MonetaryInputPolicy.validate(
                roundTrip.amount,
                currency: roundTrip.currency,
                preserving: legacyAmount
            )
        )
        XCTAssertThrowsError(
            try MonetaryInputPolicy.validate(
                roundTrip.amount,
                currency: roundTrip.currency
            )
        )
    }

    func testNewWriteMaximumLeavesHeadroomForTwentyThousandAdditions() throws {
        let aggregate = try CheckedDecimal.multiplying(
            MonetaryInputPolicy.maximumAbsoluteNewWrite,
            Decimal(MonetaryInputPolicy.aggregateRecordBudget)
        )

        XCTAssertFalse(aggregate.isNaN)
        XCTAssertEqual(
            aggregate,
            Decimal(string: "19999999999999980000")
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
