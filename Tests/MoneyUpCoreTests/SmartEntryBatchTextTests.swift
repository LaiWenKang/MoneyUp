import Foundation
@testable import MoneyUpCore
import XCTest

final class SmartEntryBatchTextTests: XCTestCase {
    func testNotesAndMixedLanguageStayWithTheirOwnLines() throws {
        let lines = try SmartEntryBatchText.lines(from: "1. lunch SGD12; with Sam\r\n2、昨天 午餐 20；退款说明\n• transfer 10 from Cash to Bank")
        XCTAssertEqual(lines, ["lunch SGD12; with Sam", "昨天 午餐 20；退款说明", "transfer 10 from Cash to Bank"])
    }

    func testNumberingDoesNotConsumeDecimalOrNegativeAmounts() throws {
        XCTAssertEqual(try SmartEntryBatchText.lines(from: "12.50 Cash\n-12 Cash"), ["12.50 Cash", "-12 Cash"])
    }

    func testExplicitMultilineSplitRequiresAnExplicitSeparateReviewChoice() throws {
        let text = "split Cash Food12 + Transport8\nFood3"
        XCTAssertThrowsError(try SmartEntryBatchText.lines(from: text))
        XCTAssertEqual(try SmartEntryBatchText.lines(from: text, explicitlySeparate: true).count, 2)
    }

    func testBatchBoundsAndBlankLinesDoNotDropRealEntries() throws {
        XCTAssertThrowsError(try SmartEntryBatchText.lines(from: "one line"))
        XCTAssertThrowsError(try SmartEntryBatchText.lines(from: Array(repeating: "lunch12", count: 33).joined(separator: "\n")))
        XCTAssertThrowsError(try SmartEntryBatchText.lines(from: String(repeating: "午餐12\n", count: 4_000)))
        XCTAssertEqual(try SmartEntryBatchText.lines(from: "\n lunch 12 \n\n unknown \n"), ["lunch 12", "unknown"])
    }

    func testSemicolonNotesCannotSwallowLaterTransactions() {
        let result = SmartEntryInterpreter.interpret("lunch 12; with Sam\ncoffee 4; with Mei", accounts: [])
        XCTAssertEqual(result.shape, .multiple)
        XCTAssertTrue(result.issues.contains(.multiple))
        XCTAssertNil(result.parsed.draft.amount)
    }
}
