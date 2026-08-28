import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

final class CSVImportNameResolverTests: XCTestCase {
    func testReviewedNamesCollapseCaseAndDiacriticVariantsInEveryDomain() {
        let date = Date(timeIntervalSinceReferenceDate: 1)
        let preview = CSVImportPreview(
            rows: [
                ImportedTransaction(
                    id: "expense-a",
                    sourceLine: 2,
                    kind: .expense,
                    occurredAt: date,
                    amount: 1,
                    accountName: "Cash",
                    categoryName: "Café"
                ),
                ImportedTransaction(
                    id: "expense-b",
                    sourceLine: 3,
                    kind: .expense,
                    occurredAt: date,
                    amount: 2,
                    accountName: "CASH",
                    categoryName: "Cafe"
                ),
                ImportedTransaction(
                    id: "income-a",
                    sourceLine: 4,
                    kind: .income,
                    occurredAt: date,
                    amount: 3,
                    accountName: "Wallet",
                    categoryName: "Salary"
                ),
                ImportedTransaction(
                    id: "income-b",
                    sourceLine: 5,
                    kind: .income,
                    occurredAt: date,
                    amount: 4,
                    accountName: "WALLET",
                    categoryName: "Sálary"
                )
            ],
            issues: []
        )
        let locale = Locale(identifier: "en_US_POSIX")
        let accountNames = CSVImportNameResolver.sourceNames(
            in: preview,
            domain: .account,
            locale: locale
        )
        let expenseNames = CSVImportNameResolver.sourceNames(
            in: preview,
            domain: .expenseCategory,
            locale: locale
        )
        let incomeNames = CSVImportNameResolver.sourceNames(
            in: preview,
            domain: .incomeCategory,
            locale: locale
        )

        XCTAssertEqual(accountNames, ["Cash", "Wallet"])
        XCTAssertEqual(expenseNames, ["Café"])
        XCTAssertEqual(incomeNames, ["Salary"])

        let accountID = UUID()
        let expenseID = UUID()
        let incomeID = UUID()
        XCTAssertEqual(
            CSVImportNameResolver.reviewedMappings(
                for: ["Cash", "CASH"],
                locale: locale,
                selectedID: { _ in accountID }
            ),
            ["cash": accountID]
        )
        XCTAssertEqual(
            CSVImportNameResolver.reviewedMappings(
                for: ["Café", "Cafe"],
                locale: locale,
                selectedID: { _ in expenseID }
            ),
            ["cafe": expenseID]
        )
        XCTAssertEqual(
            CSVImportNameResolver.reviewedMappings(
                for: ["Salary", "Sálary"],
                locale: locale,
                selectedID: { _ in incomeID }
            ),
            ["salary": incomeID]
        )
    }
}
