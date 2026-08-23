import Foundation
@testable import MoneyUpCore
import XCTest

final class TransactionFactoryTests: XCTestCase {
    func testExpenseProducesBalancedCategoryAndAccountPostings() throws {
        let sgd = try CurrencyCode("SGD")
        let accountID = UUID()
        let categoryID = UUID()
        let entry = try TransactionFactory.expense(
            amount: try Money(12.50, currency: sgd),
            paidFrom: accountID,
            category: categoryID,
            payee: "  Cafe  ",
            note: "   "
        )

        XCTAssertEqual(entry.kind, .expense)
        XCTAssertEqual(entry.payee, "Cafe")
        XCTAssertNil(entry.note)
        XCTAssertEqual(entry.postings[0].accountID, categoryID)
        XCTAssertEqual(entry.postings[0].money.amount, 12.50)
        XCTAssertEqual(entry.postings[1].accountID, accountID)
        XCTAssertEqual(entry.postings[1].money.amount, -12.50)
        XCTAssertEqual(entry.balanceByCurrency[sgd], Decimal.zero)
    }

    func testForeignTransferBalancesBothCurrencies() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let entry = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(135, currency: sgd),
            destinationAmount: try Money(100, currency: usd),
            from: UUID(),
            to: UUID(),
            sourceTradingAccountID: UUID(),
            destinationTradingAccountID: UUID()
        )

        XCTAssertEqual(entry.postings.count, 4)
        XCTAssertEqual(entry.balanceByCurrency[sgd], Decimal.zero)
        XCTAssertEqual(entry.balanceByCurrency[usd], Decimal.zero)
    }

    func testTransferRejectsSameAccountAndNonPositiveAmount() throws {
        let sgd = try CurrencyCode("SGD")
        let accountID = UUID()

        XCTAssertThrowsError(
            try TransactionFactory.transfer(
                amount: try Money(1, currency: sgd),
                from: accountID,
                to: accountID
            )
        ) { error in
            XCTAssertEqual(error as? TransactionFactoryError, .accountsMustDiffer)
        }

        XCTAssertThrowsError(
            try TransactionFactory.expense(
                amount: Money.zero(currency: sgd),
                paidFrom: accountID,
                category: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? TransactionFactoryError, .amountMustBePositive)
        }
    }

    func testBalanceAdjustmentUsesUserFacingLiabilitySign() throws {
        let sgd = try CurrencyCode("SGD")
        let cardID = UUID()
        let equityID = UUID()
        let entry = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(500, currency: sgd),
            accountID: cardID,
            equityAccountID: equityID,
            accountIsLiability: true
        )

        XCTAssertEqual(entry.kind, .adjustment)
        XCTAssertEqual(entry.postings[0].accountID, cardID)
        XCTAssertEqual(entry.postings[0].money.amount, -500)
        XCTAssertEqual(entry.postings[1].accountID, equityID)
        XCTAssertEqual(entry.postings[1].money.amount, 500)
        XCTAssertEqual(entry.balanceByCurrency[sgd], Decimal.zero)
    }
}
