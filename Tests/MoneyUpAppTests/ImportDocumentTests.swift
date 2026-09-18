import Foundation
import MoneyUpCore
@testable import MoneyUp
import XCTest

final class ImportDocumentTests: XCTestCase {
    func testJSONKeepsDecimalAmountsAndLargeNumericIdentitiesExact() throws {
        let json = #"[{"id":9007199254740993,"date":"2026-09-18 12:00:00","type":"expense","amount":12.80,"category":{"name":"Food"},"note":"早餐 👩‍🍳"}]"#
        let table = try XCTUnwrap(ImportDocument.decode(Data(json.utf8)).tables.first)
        let id = try XCTUnwrap(table.rows[0].firstIndex(of: "id"))
        XCTAssertEqual(table.rows[1][id], "9007199254740993")
        XCTAssertTrue(table.rows[0].contains("category.name"))
        XCTAssertTrue(try table.csv().contains("早餐 👩‍🍳"))
        let preview = try TransactionCSVImporter.parse(table.csv())
        XCTAssertEqual(preview.rows.first?.amount, Decimal(string: "12.80"))
        XCTAssertEqual(preview.rows.first?.note, "早餐 👩‍🍳")
        XCTAssertTrue(preview.rows.first?.hasExternalID == true)
        XCTAssertThrowsError(try JSONImportReader.tables(Data("[{\"amount\":1234567890123456789012345678901234567890123}]".utf8)))
        let decimalJSON = try ImportDocument.decode(Data(#"[{"date":"2026-09-18","type":"expense","amount":1.234,"currency":"KWD"}]"#.utf8))
        let decimalTable = try XCTUnwrap(decimalJSON.tables.first)
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(try TransactionCSVImporter.parse(decimalTable.csv(locale: german), locale: german).rows.first?.amount,
                       Decimal(string: "1.234"))
    }

    func testJSONTablesRequireAnExplicitChoiceAndIgnoreScalarMetadataLists() throws {
        let json = #"{"tags":["home","work"],"books":{"personal":[{"date":"2026-09-18","type":"expense","amount":1}],"shared":[{"date":"2026-09-18","type":"income","amount":2}]}}"#
        let document = try ImportDocument.decode(Data(json.utf8))
        XCTAssertEqual(document.tables.map(\.name), ["books.personal", "books.shared"])
        XCTAssertThrowsError(try JSONImportReader.tables(Data("[{\"amount\":1},false]".utf8)))
        XCTAssertThrowsError(try JSONImportReader.tables(Data((String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)).utf8)))
    }

    func testXLSXReadsDeflateSharedStringsSparseCellsAndStyledDates() throws {
        let document = try ImportDocument.decode(fixture("ledger"))
        XCTAssertEqual(document.tables.map(\.name), ["Ledger", "Summary"])
        let table = try XCTUnwrap(document.tables.first)
        XCTAssertEqual(table.rows[1][0], "2026-09-18 12:00:00.000")
        XCTAssertEqual(table.rows[1][try XCTUnwrap(table.rows[0].firstIndex(of: "note"))], "早餐 & coffee")
        let preview = try TransactionCSVImporter.parse(table.csv(), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(preview.issues.isEmpty)
        XCTAssertEqual(preview.rows.first?.amount, Decimal(string: "12.80"))
        XCTAssertEqual(preview.rows.first?.kind, .expense)
        let precise = try XCTUnwrap(ImportDocument.decode(fixture("locale-decimal")).tables.first)
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(try TransactionCSVImporter.parse(precise.csv(locale: german), locale: german).rows.first?.amount,
                       Decimal(string: "1.234"))
    }

    func testXLSXDoesNotExecuteFormulasOrExternalEntities() throws {
        let table = try XCTUnwrap(ImportDocument.decode(fixture("formula")).tables.first)
        let preview = try TransactionCSVImporter.parse(table.csv())
        XCTAssertTrue(preview.rows.isEmpty)
        XCTAssertEqual(preview.issues.first?.reason, "invalid_amount")
        XCTAssertThrowsError(try ImportDocument.decode(fixture("external-entity")))
    }

    func testXLSXRejectsCorruptionAndExpansionBombBeforeImport() throws {
        let original = try fixture("ledger")
        var corrupted = original
        let name = try XCTUnwrap(corrupted.range(of: Data("xl/workbook.xml".utf8)))
        corrupted[name.upperBound + 10] ^= 0x80
        XCTAssertThrowsError(try ImportDocument.decode(corrupted))
        var oversized = original
        let central = try XCTUnwrap(oversized.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        for offset in 24..<28 { oversized[central.lowerBound + offset] = 0xff }
        XCTAssertThrowsError(try ImportDocument.decode(oversized))
    }

    func testDateSystemsAndQianjiAdvanceRequireCorrectExplicitInterpretation() throws {
        XCTAssertNil(ImportDateEncoding.excelDate(60, uses1904: false))
        XCTAssertEqual(ImportDateEncoding.excelDate(0, uses1904: true), "1904-01-01 00:00:00.000")
        XCTAssertEqual(ImportDateEncoding.excelDate(61, uses1904: false), "1900-03-01 00:00:00.000")
        let document = try ImportDocument.decode(Data(#"[{"time":"2026-09-18","type":5,"money":48.50,"catename":"Travel"}]"#.utf8))
        let table = try XCTUnwrap(document.tables.first)
        let mapping = try TransactionCSVImporter.inspect(table.csv()).suggestedMapping
        let blocked = try TransactionCSVImporter.parse(table.csv(mapping: mapping, qianjiTypes: true), mapping: mapping)
        XCTAssertTrue(blocked.rows.isEmpty)
        let reviewed = try TransactionCSVImporter.parse(table.csv(mapping: mapping, qianjiTypes: true,
            typeOverrides: ["5": "expense"]), mapping: mapping)
        XCTAssertEqual(reviewed.rows.first?.kind, .expense)
        XCTAssertEqual(reviewed.rows.first?.amount, Decimal(string: "48.50"))
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "xlsx")
            ?? bundle.url(forResource: name, withExtension: "xlsx", subdirectory: "ImportFixtures")
        return try Data(contentsOf: XCTUnwrap(url))
    }
}
