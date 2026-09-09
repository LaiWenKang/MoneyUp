import Foundation
@testable import MoneyUpCore
import XCTest

final class SmartEntryInterpreterTests: XCTestCase {
    private func accounts() throws -> [LedgerAccount] {
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        return [LedgerAccount(name: "Cash", kind: .asset, currency: sgd),
            LedgerAccount(name: "Bank", kind: .asset, currency: sgd),
            LedgerAccount(name: "支付宝", kind: .asset, currency: sgd),
            LedgerAccount(name: "USD Wallet", kind: .asset, currency: usd),
            LedgerAccount(name: "Food", kind: .expense), LedgerAccount(name: "Transport", kind: .expense)]
    }

    func testDirectedTransfersInBothLanguagesAndReverseWordOrder() throws {
        let accounts = try accounts()
        for phrase in ["transfer 20 from Cash to Bank", "transfer 20 to Bank from Cash"] {
            let result = SmartEntryInterpreter.interpret(phrase, accounts: accounts)
            XCTAssertEqual(result.shape, .transfer)
            XCTAssertEqual(result.sourceAccountID, accounts[0].id)
            XCTAssertEqual(result.destinationAccountID, accounts[1].id)
            XCTAssertEqual(result.parsed.draft.amount, 20)
            XCTAssertTrue(result.issues.isEmpty)
        }
        let contextual = SmartEntryInterpreter.interpret("20 to Bank", accounts: accounts, expectsTransfer: true)
        XCTAssertEqual(contextual.shape, .transfer)
        XCTAssertNil(contextual.sourceAccountID)
        XCTAssertEqual(contextual.destinationAccountID, accounts[1].id)
        XCTAssertTrue(contextual.issues.contains(.account))
        let chinese = SmartEntryInterpreter.interpret("从支付宝转账到Bank 20", accounts: accounts)
        XCTAssertEqual(chinese.sourceAccountID, accounts[2].id)
        XCTAssertEqual(chinese.destinationAccountID, accounts[1].id)
    }

    func testForeignTransferNeverInventsReceivedAmountOrExchangeRate() throws {
        let accounts = try accounts()
        let missing = SmartEntryInterpreter.interpret("transfer SGD10 from Cash to USD Wallet", accounts: accounts)
        XCTAssertNil(missing.destinationAmount)
        XCTAssertTrue(missing.issues.contains(.receivedAmount))
        let now = Date(timeIntervalSince1970: 1_788_933_600)
        let exact = SmartEntryInterpreter.interpret("transfer SGD10 from Cash to USD Wallet received USD7.50 yesterday; fee included", accounts: accounts, now: now)
        XCTAssertEqual(exact.parsed.draft.amount, 10)
        XCTAssertEqual(exact.destinationAmount, Decimal(string: "7.50"))
        XCTAssertEqual(exact.parsed.currencyEvidence.identifiedCurrency?.value, "SGD")
        XCTAssertEqual(exact.destinationCurrencyEvidence.identifiedCurrency?.value, "USD")
        XCTAssertEqual(exact.parsed.note, "fee included")
        XCTAssertEqual(exact.parsed.draft.occurredAt, Calendar.current.date(byAdding: .day, value: -1, to: now))
    }

    func testUndirectedAndSameAccountTransfersRemainUnresolved() throws {
        let accounts = try accounts()
        for phrase in ["transfer 20 Cash Bank", "transfer 20 from Cash to Cash", "transfer 20 to Missing"] {
            let result = SmartEntryInterpreter.interpret(phrase, accounts: accounts)
            XCTAssertEqual(result.shape, .transfer)
            XCTAssertTrue(result.issues.contains(.destination))
        }
    }

    func testExplicitSplitsConserveAmountsAndValidateDeclaredTotal() throws {
        let accounts = try accounts()
        for phrase in ["split Cash Food12 + Transport8", "拆分 Cash Food 12 + Transport 8", "split Cash Food12 + Transport8 total20"] {
            let result = SmartEntryInterpreter.interpret(phrase, accounts: accounts)
            XCTAssertEqual(result.shape, .split, phrase)
            XCTAssertEqual(result.parsed.draft.amount, 20, phrase)
            XCTAssertEqual(result.splits.map(\.amount), [12, 8], phrase)
            XCTAssertTrue(result.issues.isEmpty, phrase)
        }
        for phrase in ["split Cash Food12 + Transport8 total25", "split Cash Food12 + Unknown8"] {
            XCTAssertTrue(SmartEntryInterpreter.interpret(phrase, accounts: accounts).issues.contains(.split))
        }
    }

    func testIndependentLinesAreNotCollapsedIntoASplitOrSingleTransaction() throws {
        let result = SmartEntryInterpreter.interpret("Cash lunch 12\nBank taxi 8", accounts: try accounts())
        XCTAssertEqual(result.shape, .multiple)
        XCTAssertTrue(result.issues.contains(.multiple))
        XCTAssertTrue(result.splits.isEmpty)
    }

    func testRelativeDatesPreserveLocalClockAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 14, minute: 30)))
        for phrase in ["coffee 12 3 days ago", "3天前咖啡12"] {
            let value = SmartEntryInterpreter.interpret(phrase, accounts: [], now: now, calendar: calendar)
            XCTAssertEqual(value.parsed.draft.amount, 12)
            let date = try XCTUnwrap(value.parsed.draft.occurredAt)
            XCTAssertEqual(calendar.component(.day, from: date), 6)
            XCTAssertEqual(calendar.component(.hour, from: date), 14)
            XCTAssertEqual(calendar.component(.minute, from: date), 30)
        }
    }

    func testConflictingDatesDuplicateNamesAndHugeInputRequireReview() throws {
        let first = LedgerAccount(name: "Shared", kind: .asset)
        let second = LedgerAccount(name: "Shared", kind: .asset)
        let name = SmartEntryInterpreter.interpret("Shared lunch 12", accounts: [first, second])
        XCTAssertNil(name.parsed.draft.accountID)
        XCTAssertTrue(name.issues.contains(.account))
        let date = SmartEntryInterpreter.interpret("lunch 12 yesterday tomorrow", accounts: [])
        XCTAssertNil(date.parsed.draft.occurredAt)
        XCTAssertTrue(date.issues.contains(.date))
        for phrase in ["lunch 12 last week", "上周午餐12", "9月8日 午餐12"] {
            XCTAssertTrue(SmartEntryInterpreter.interpret(phrase, accounts: []).issues.contains(.date), phrase)
        }
        let large = SmartEntryInterpreter.interpret(String(repeating: "午餐", count: 10_000), accounts: [])
        XCTAssertEqual(large.issues, [.inputLimit])
        XCTAssertNil(large.parsed.context)
    }
}
