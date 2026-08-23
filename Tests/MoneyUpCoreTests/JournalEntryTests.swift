import Foundation
@testable import MoneyUpCore
import XCTest

final class JournalEntryTests: XCTestCase {
    func testBalancedExpenseIsAccepted() throws {
        let sgd = try CurrencyCode("SGD")
        let expenseAccountID = UUID()
        let bankAccountID = UUID()

        let entry = try JournalEntry(
            kind: .expense,
            postings: [
                Posting(
                    accountID: expenseAccountID,
                    money: try Money(5, currency: sgd)
                ),
                Posting(
                    accountID: bankAccountID,
                    money: try Money(-5, currency: sgd)
                )
            ]
        )

        XCTAssertEqual(entry.balanceByCurrency[sgd], .zero)
    }

    func testUnbalancedEntryIsRejected() throws {
        let sgd = try CurrencyCode("SGD")

        XCTAssertThrowsError(
            try JournalEntry(
                kind: .expense,
                postings: [
                    Posting(
                        accountID: UUID(),
                        money: try Money(5, currency: sgd)
                    ),
                    Posting(
                        accountID: UUID(),
                        money: try Money(-4, currency: sgd)
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? JournalEntryValidationError,
                .unbalanced(currency: sgd, residual: 1)
            )
        }
    }

    func testEveryCurrencyBalancesIndependently() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let sgdTradingAccount = UUID()
        let usdTradingAccount = UUID()

        let entry = try JournalEntry(
            kind: .transfer,
            postings: [
                Posting(
                    accountID: UUID(),
                    money: try Money(-100, currency: sgd)
                ),
                Posting(
                    accountID: sgdTradingAccount,
                    money: try Money(100, currency: sgd)
                ),
                Posting(
                    accountID: usdTradingAccount,
                    money: try Money(-75, currency: usd)
                ),
                Posting(
                    accountID: UUID(),
                    money: try Money(75, currency: usd)
                )
            ]
        )

        XCTAssertEqual(entry.balanceByCurrency[sgd], .zero)
        XCTAssertEqual(entry.balanceByCurrency[usd], .zero)
    }

    func testZeroPostingIsRejected() throws {
        let sgd = try CurrencyCode("SGD")
        let zeroPosting = Posting(
            accountID: UUID(),
            money: Money.zero(currency: sgd)
        )

        XCTAssertThrowsError(
            try JournalEntry(
                kind: .adjustment,
                postings: [
                    zeroPosting,
                    Posting(
                        accountID: UUID(),
                        money: try Money(1, currency: sgd)
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? JournalEntryValidationError,
                .zeroPosting(zeroPosting.id)
            )
        }
    }
}
