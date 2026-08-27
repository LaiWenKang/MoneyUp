import Foundation
@testable import MoneyUpCore
import XCTest

final class CheckedDecimalTests: XCTestCase {
    func testOrdinaryExactOperations() throws {
        XCTAssertEqual(try CheckedDecimal.adding(10, 2), 12)
        XCTAssertEqual(try CheckedDecimal.subtracting(10, 2), 8)
        XCTAssertEqual(try CheckedDecimal.multiplying(10, 2), 20)
        XCTAssertEqual(try CheckedDecimal.dividing(10, 2), 5)
    }

    func testStrictDivisionRejectsRepeatingResultButPresentationRatioAllowsIt() throws {
        XCTAssertThrowsError(try CheckedDecimal.dividing(1, 3)) { error in
            XCTAssertEqual(error as? DecimalCalculationError, .lossOfPrecision)
        }

        let ratio = try CheckedDecimal.ratio(1, 3)
        XCTAssertGreaterThan(ratio, Decimal(string: "0.333")!)
        XCTAssertLessThan(ratio, Decimal(string: "0.334")!)
    }

    func testDivisionByZeroIsRejectedForEveryDivisionMode() {
        XCTAssertThrowsError(try CheckedDecimal.dividing(1, 0)) { error in
            XCTAssertEqual(error as? DecimalCalculationError, .divideByZero)
        }
        XCTAssertThrowsError(try CheckedDecimal.ratio(1, 0)) { error in
            XCTAssertEqual(error as? DecimalCalculationError, .divideByZero)
        }
    }

    func testOverflowFromExtremeLegacyDecimalsIsRejected() throws {
        let huge = try XCTUnwrap(
            Decimal(
                string: "9e127",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        XCTAssertThrowsError(try CheckedDecimal.multiplying(huge, 2)) { error in
            XCTAssertEqual(error as? DecimalCalculationError, .overflow)
        }
    }

    func testCancellationSensitivePrecisionLossIsNotHiddenByLaterValues() throws {
        let huge = try XCTUnwrap(
            Decimal(
                string: "9e127",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        XCTAssertThrowsError(try CheckedDecimal.adding(huge, 1)) { error in
            XCTAssertEqual(error as? DecimalCalculationError, .lossOfPrecision)
        }
    }

    func testCurrencyHelpersRoundExactlyOnceToDestinationMinorUnits() throws {
        let sgd = try CurrencyCode("SGD")
        let jpy = try CurrencyCode("JPY")

        XCTAssertEqual(
            try CheckedDecimal.divideForCurrencyRounding(10, 3, currency: sgd),
            Decimal(string: "3.33")
        )
        XCTAssertEqual(
            try CheckedDecimal.productForCurrencyRounding(
                Decimal(string: "1.005")!,
                1,
                currency: sgd
            ),
            1
        )
        XCTAssertEqual(
            try CheckedDecimal.divideForCurrencyRounding(10, 3, currency: jpy),
            3
        )
    }

    func testOperationObservesTaskCancellation() async {
        let operation = Task<Decimal, Error> {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try CheckedDecimal.adding(1, 2)
        }

        do {
            _ = try await operation.value
            XCTFail("Cancelled arithmetic must not return a value")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error))")
        }
    }
}
