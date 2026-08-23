import Foundation
@testable import MoneyUpCore
import XCTest

final class ScheduledAndHoldingTests: XCTestCase {
    func testMonthlyScheduleGeneratesBoundedOccurrences() throws {
        let sgd = try CurrencyCode("SGD")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))
        )
        let end = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(1_000, currency: sgd),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: start,
            frequency: .monthly
        )

        let dates = schedule.occurrences(through: end, calendar: calendar)

        XCTAssertEqual(dates.count, 4)
        XCTAssertEqual(calendar.component(.month, from: dates.last!), 4)
    }

    func testScheduleRejectsTransferAndZeroAmount() throws {
        let sgd = try CurrencyCode("SGD")

        XCTAssertThrowsError(
            try ScheduledTransaction(
                kind: .transfer,
                name: "Transfer",
                amount: try Money(1, currency: sgd),
                accountID: UUID(),
                categoryAccountID: UUID(),
                nextOccurrence: Date(),
                frequency: .monthly
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .unsupportedKind)
        }

        XCTAssertThrowsError(
            try ScheduledTransaction(
                kind: .expense,
                name: "Invalid",
                amount: Money.zero(currency: sgd),
                accountID: UUID(),
                categoryAccountID: UUID(),
                nextOccurrence: Date(),
                frequency: .monthly
            )
        ) { error in
            XCTAssertEqual(error as? ScheduledTransactionError, .amountMustBePositive)
        }
    }

    func testInvestmentMarketValueUsesDecimalArithmetic() throws {
        let usd = try CurrencyCode("USD")
        let holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: " mu ",
            name: "Micron",
            quantity: Decimal(string: "1.25")!,
            price: try Money(Decimal(string: "100.40")!, currency: usd),
            priceAsOf: Date()
        )

        let value = try holding.marketValue()

        XCTAssertEqual(holding.symbol, "MU")
        XCTAssertEqual(value?.amount, Decimal(string: "125.500")!)
        XCTAssertEqual(value?.currency, usd)
    }
}
