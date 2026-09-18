import CoreFoundation
import Foundation
import MoneyUpCore
@testable import MoneyUp
import UniformTypeIdentifiers
import XCTest

final class DelimitedImportFileTests: XCTestCase {
    private let csv = "时间,类型,分类,金额,账户,备注\n2026-09-18 09:00:00,支出,餐饮,12.80,现金,早餐\n"

    func testQianjiCSVSurvivesUTF8BOMAndUTF16Exports() throws {
        for bytes in [Data(csv.utf8), Data([0xef, 0xbb, 0xbf]) + Data(csv.utf8), try XCTUnwrap(csv.data(using: .utf16))] {
            let decoded = try DelimitedImportFile.decode(bytes)
            let preview = try TransactionCSVImporter.parse(decoded, locale: Locale(identifier: "zh_CN"), timeZone: TimeZone(secondsFromGMT: 0)!)
            XCTAssertEqual(preview.rows.count, 1)
            XCTAssertTrue(preview.issues.isEmpty)
            XCTAssertEqual(preview.rows.first?.amount, Decimal(string: "12.80"))
            XCTAssertEqual(preview.rows.first?.categoryName, "餐饮")
        }
    }

    func testOlderWindowsChineseExportPreservesTextAndExactAmount() throws {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let bytes = try XCTUnwrap(csv.data(using: String.Encoding(rawValue: encoding)))
        XCTAssertEqual(try DelimitedImportFile.decode(bytes), csv)
    }

    func testCSVWithProviderExcelLabelCanBeChosenAndRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in ["csv", "xls", "unknown"] {
            let file = directory.appendingPathComponent("钱迹账单." + ext)
            try Data(csv.utf8).write(to: file)
            XCTAssertEqual(try DelimitedImportFile.read(file), csv)
            let providerType = UTType(filenameExtension: ext) ?? .data
            XCTAssertTrue(DelimitedImportFile.allowedContentTypes.contains { providerType.conforms(to: $0) })
        }
        let opaqueProviderType = try XCTUnwrap(UTType(tag: "qianji-opaque-export", tagClass: .filenameExtension, conformingTo: .item))
        XCTAssertFalse(opaqueProviderType.conforms(to: .text))
        XCTAssertTrue(DelimitedImportFile.allowedContentTypes.contains { opaqueProviderType.conforms(to: $0) })
        XCTAssertThrowsError(try DelimitedImportFile.readData(directory))
    }

    func testBinaryWorkbookIsNotMisreadAsText() {
        for bytes in [Data([0x50, 0x4b, 0x03, 0x04, 0, 0]), Data([0xd0, 0xcf, 0x11, 0xe0, 0, 0])] {
            XCTAssertThrowsError(try DelimitedImportFile.decode(bytes)) { error in
                guard case CSVImportViewError.requiresCSVExport = error else {
                    return XCTFail("A real Excel or ZIP file must request a CSV export")
                }
            }
        }
        XCTAssertThrowsError(try DelimitedImportFile.decode(Data([65, 0, 66, 0])))
    }

    func testEmptyAndOversizedFilesFailBeforeParsing() {
        XCTAssertThrowsError(try DelimitedImportFile.decode(Data()))
        XCTAssertThrowsError(try DelimitedImportFile.decode(Data(repeating: 65, count: TransactionCSVImporter.maximumInputByteCount + 1)))
    }
}
