import Foundation
@testable import MoneyUpCore
import XCTest

final class ReceiptTextParserTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return try XCTUnwrap(calendar.date(from: components))
    }

    func testReadsGrandTotalRatherThanSubtotalOrTax() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "FAIRPRICE FINEST",
                "313 Somerset",
                "Bread          3.20",
                "Milk           4.50",
                "Subtotal      27.10",
                "GST 9%         2.44",
                "TOTAL         29.54",
                "Cash          50.00",
                "Change        20.46"
            ],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "29.54"))
        XCTAssertEqual(draft.payee, "FAIRPRICE FINEST")
        XCTAssertEqual(draft.kind, .expense)
        XCTAssertEqual(draft.source, .receipt)
    }

    func testReadsChineseReceiptTotal() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "海底捞火锅",
                "小计        168.00",
                "服务费       16.80",
                "合计        184.80",
                "2026年03月18日"
            ],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "184.80"))
        XCTAssertEqual(draft.payee, "海底捞火锅")
        XCTAssertEqual(draft.occurredAt, try date(2026, 3, 18, hour: 0))
    }

    func testReadsTotalPrintedOnTheLineBelowItsLabel() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Cafe Nero", "Amount Due", "12.40"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "12.40"))
    }

    func testIgnoresCardAndPhoneNumbersWhenNoTotalIsLabelled() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "Corner Store",
                "Tel 6581234567",
                "VISA 4111111111111111",
                "8.75"
            ],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "8.75"))
    }

    func testGivesUpRatherThanGuessingWhenNoDecimalAmountExists() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Corner Store", "Tel 6581234567", "Order 88231"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertNil(draft.amount)
    }

    func testRejectsADateFarOutsideThePlausibleRange() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Shop", "Best before 2031/01/01", "TOTAL 5.00"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertNil(draft.occurredAt)
        XCTAssertEqual(draft.amount, Decimal(5))
    }

    func testDayFirstAndMonthFirstReadingsFollowTheLocale() throws {
        let lines = ["Shop", "05/03/2026", "TOTAL 5.00"]

        let dayFirst = ReceiptTextParser.draft(
            fromLines: lines,
            now: try date(2026, 6, 1),
            calendar: calendar,
            prefersDayFirst: true
        )
        let monthFirst = ReceiptTextParser.draft(
            fromLines: lines,
            now: try date(2026, 6, 1),
            calendar: calendar,
            prefersDayFirst: false
        )

        XCTAssertEqual(dayFirst.occurredAt, try date(2026, 3, 5, hour: 0))
        XCTAssertEqual(monthFirst.occurredAt, try date(2026, 5, 3, hour: 0))
    }

    func testUnambiguousDayAboveTwelveOverridesTheLocale() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Shop", "19/03/2026", "TOTAL 5.00"],
            now: try date(2026, 6, 1),
            calendar: calendar,
            prefersDayFirst: false
        )

        XCTAssertEqual(draft.occurredAt, try date(2026, 3, 19, hour: 0))
    }

    func testThousandsSeparatorsAreRead() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Furniture Co", "TOTAL 1,299.00"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(1299))
    }

    func testEmptyScanProducesAnEmptyDraft() {
        let draft = ReceiptTextParser.draft(fromLines: ["", "   "])
        XCTAssertTrue(draft.isEmpty)
    }
}
