import Foundation
@testable import MoneyUpCore
import XCTest

final class LedgerCSVExporterTests: XCTestCase {
    func testExportPreservesPostingRowsAndEscapesText() throws {
        let sgd = try CurrencyCode("SGD")
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let firstPostingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let secondPostingID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let expenseAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let bankAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let instant = Date(timeIntervalSince1970: 0)
        let entry = try JournalEntry(
            id: entryID,
            kind: .expense,
            occurredAt: instant,
            createdAt: instant,
            payee: "Cafe, \"A\"",
            note: "Breakfast",
            postings: [
                Posting(
                    id: firstPostingID,
                    accountID: expenseAccountID,
                    money: try Money(5.25, currency: sgd),
                    memo: "Meal"
                ),
                Posting(
                    id: secondPostingID,
                    accountID: bankAccountID,
                    money: try Money(-5.25, currency: sgd)
                )
            ]
        )

        let csv = LedgerCSVExporter.export([entry])
        let lines = csv.components(separatedBy: "\r\n")

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(csv.contains("\"Cafe, \"\"A\"\"\""))
        XCTAssertTrue(csv.contains(",5.25,SGD,"))
        XCTAssertTrue(csv.contains(",-5.25,SGD,"))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testExportNeutralizesFormulaInjectionInUserText() throws {
        let sgd = try CurrencyCode("SGD")
        let entry = try JournalEntry(
            kind: .expense,
            payee: "=HYPERLINK(\"https://example.invalid\")",
            postings: [
                Posting(
                    accountID: UUID(),
                    money: try Money(1, currency: sgd),
                    memo: "@malicious"
                ),
                Posting(
                    accountID: UUID(),
                    money: try Money(-1, currency: sgd)
                )
            ]
        )

        let csv = LedgerCSVExporter.export([entry])

        XCTAssertTrue(csv.contains("'=HYPERLINK"))
        XCTAssertTrue(csv.contains("'@malicious"))
    }

    func testExportIncludesReadableAccountMetadata() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(
            name: "Everyday Bank",
            kind: .asset,
            currency: sgd,
            accountType: .bank
        )
        let dining = LedgerAccount(name: "Dining", kind: .expense)
        let entry = try TransactionFactory.expense(
            amount: try Money(9.75, currency: sgd),
            paidFrom: bank.id,
            category: dining.id
        )

        let csv = LedgerCSVExporter.export([entry], accounts: [bank, dining])

        XCTAssertTrue(csv.contains("account_name,account_kind,account_type"))
        XCTAssertTrue(csv.contains("Everyday Bank,asset,bank"))
        XCTAssertTrue(csv.contains("Dining,expense"))
    }
}
