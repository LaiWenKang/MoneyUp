import Foundation
@testable import MoneyUpCore
import XCTest

final class FinanceCalculatorTests: XCTestCase {
    func testAssetAndLiabilityBalancesUseUserFacingSigns() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(
            name: "Bank",
            kind: .asset,
            currency: sgd,
            accountType: .bank
        )
        let card = LedgerAccount(
            name: "Card",
            kind: .liability,
            currency: sgd,
            accountType: .creditCard
        )
        let dining = LedgerAccount(name: "Dining", kind: .expense)
        let bankExpense = try TransactionFactory.expense(
            amount: try Money(20, currency: sgd),
            paidFrom: bank.id,
            category: dining.id
        )
        let cardExpense = try TransactionFactory.expense(
            amount: try Money(30, currency: sgd),
            paidFrom: card.id,
            category: dining.id
        )

        let bankBalance = try FinanceCalculator.displayBalance(
            for: bank,
            entries: [bankExpense, cardExpense]
        )
        let cardBalance = try FinanceCalculator.displayBalance(
            for: card,
            entries: [bankExpense, cardExpense]
        )

        XCTAssertEqual(bankBalance?.amount, -20)
        XCTAssertEqual(cardBalance?.amount, 30)
    }

    func testTransfersDoNotIncreaseSpending() throws {
        let sgd = try CurrencyCode("SGD")
        let source = LedgerAccount(name: "Source", kind: .asset, currency: sgd)
        let destination = LedgerAccount(name: "Destination", kind: .asset, currency: sgd)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let transfer = try TransactionFactory.transfer(
            amount: try Money(100, currency: sgd),
            from: source.id,
            to: destination.id
        )
        let expense = try TransactionFactory.expense(
            amount: try Money(8, currency: sgd),
            paidFrom: destination.id,
            category: food.id
        )

        let spending = try FinanceCalculator.spendingByCategory(
            accounts: [source, destination, food],
            entries: [transfer, expense],
            currency: sgd
        )

        XCTAssertEqual(spending[food.id]?.amount, 8)
        XCTAssertEqual(spending.count, 1)
    }

    func testPeriodEndIsExcludedFromLegacyCalculators() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let atStart = try TransactionFactory.expense(
            amount: try Money(10, currency: sgd),
            paidFrom: bank.id,
            category: food.id,
            occurredAt: start
        )
        let atEnd = try TransactionFactory.expense(
            amount: try Money(20, currency: sgd),
            paidFrom: bank.id,
            category: food.id,
            occurredAt: end
        )

        let spending = try FinanceCalculator.spendingByCategory(
            accounts: [bank, food],
            entries: [atStart, atEnd],
            currency: sgd,
            interval: DateInterval(start: start, end: end)
        )
        XCTAssertEqual(spending[food.id]?.amount, 10)
    }
}
