import Foundation
import MoneyUpCore

enum XLSXImportReader {
    private struct WorksheetData {
        let rows: [[String]]
        let numbers: Set<ImportNumericCell>
    }
    static func tables(_ data: Data) throws -> [ImportDataTable] {
        let archive = try XLSXZipArchive(data)
        guard let bookData = try archive.file("xl/workbook.xml"),
              let relationshipData = try archive.file("xl/_rels/workbook.xml.rels") else { throw CSVImportViewError.unsupportedDocument }
        let book = try XLSXXMLDocument.parse(bookData)
        let relationships = try XLSXXMLDocument.parse(relationshipData)
        let sharedStrings = try strings(archive)
        let dateStyles = try dateStyleIndexes(archive)
        let uses1904 = ["1", "true"].contains(book.child("workbookPr")?.attributes["date1904"] ?? "")
        var tables: [ImportDataTable] = []
        for sheet in book.child("sheets")?.children ?? [] where sheet.name == "sheet" {
            try Task.checkCancellation()
            guard tables.count < 32, let id = sheet.attributes.first(where: { $0.key.hasSuffix(":id") })?.value,
                  let link = relationships.children.first(where: { $0.attributes["Id"] == id }),
                  link.attributes["TargetMode"] != "External", let target = link.attributes["Target"],
                  let path = worksheetPath(target), let xml = try archive.file(path) else { throw CSVImportViewError.unsupportedDocument }
            let root = try XLSXXMLDocument.parse(xml)
            let decoded = try rows(root, strings: sharedStrings, dateStyles: dateStyles, uses1904: uses1904)
            let columns = Dictionary(uniqueKeysWithValues: ImportDataTable.populatedColumns(decoded.rows).enumerated().map { ($0.element, $0.offset) })
            let numbers = Set(decoded.numbers.compactMap { cell in columns[cell.column].map { ImportNumericCell(row: cell.row, column: $0) } })
            let records = ImportDataTable.normalizedRows(decoded.rows)
            if !records.isEmpty {
                _ = try ImportDataTable.csv(records)
                tables.append(ImportDataTable(id: id, name: sheet.attributes["name"] ?? id, rows: records, numericCells: numbers))
            }
        }
        guard !tables.isEmpty else { throw TransactionCSVImportError.emptyFile }
        return tables
    }

    private static func worksheetPath(_ target: String) -> String? {
        guard !target.contains(":"), !target.contains("\\") else { return nil }
        let raw = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        var pieces: [String] = []
        for piece in raw.components(separatedBy: "/") {
            if piece == ".." { guard !pieces.isEmpty else { return nil }; pieces.removeLast() }
            else if piece != ".", !piece.isEmpty { pieces.append(piece) }
        }
        let path = pieces.joined(separator: "/")
        return path.hasPrefix("xl/worksheets/") && path.hasSuffix(".xml") ? path : nil
    }

    private static func strings(_ archive: XLSXZipArchive) throws -> [String] {
        guard let xml = try archive.file("xl/sharedStrings.xml") else { return [] }
        let root = try XLSXXMLDocument.parse(xml)
        let values = root.children.filter { $0.name == "si" }.map(\.content)
        guard values.count <= 200_000, values.allSatisfy({ $0.utf8.count <= TransactionCSVImporter.maximumFieldByteCount }) else {
            throw CSVImportViewError.documentTooLarge
        }
        return values
    }

    private static func dateStyleIndexes(_ archive: XLSXZipArchive) throws -> Set<Int> {
        guard let xml = try archive.file("xl/styles.xml") else { return [] }
        let root = try XLSXXMLDocument.parse(xml)
        var dateFormats: Set<Int> = [14, 15, 16, 17, 22]
        for format in root.child("numFmts")?.children ?? [] {
            guard let id = format.attributes["numFmtId"].flatMap(Int.init), let code = format.attributes["formatCode"] else { continue }
            let stripped = code.replacingOccurrences(of: #"\"[^\"]*\"|\[[^\]]*\]|\\."#, with: "", options: .regularExpression)
            if stripped.range(of: "[yd]", options: [.regularExpression, .caseInsensitive]) != nil { dateFormats.insert(id) }
        }
        return Set((root.child("cellXfs")?.children ?? []).enumerated().compactMap { index, node in
            guard let id = node.attributes["numFmtId"].flatMap(Int.init), dateFormats.contains(id) else { return nil }
            return index
        })
    }

    private static func rows(_ root: XLSXXMLNode, strings: [String], dateStyles: Set<Int>, uses1904: Bool) throws -> WorksheetData {
        var records: [[String]] = []
        var numbers: Set<ImportNumericCell> = []
        for row in root.child("sheetData")?.children ?? [] where row.name == "row" {
            try Task.checkCancellation()
            guard records.count <= 20_000 else { throw TransactionCSVImportError.tooManyRows }
            var fields: [String] = []
            var used: Set<Int> = []
            for cell in row.children where cell.name == "c" {
                let index = try column(cell.attributes["r"], fallback: fields.count)
                guard used.insert(index).inserted else { throw CSVImportViewError.unsupportedDocument }
                while fields.count <= index { fields.append("") }
                fields[index] = try value(cell, strings: strings, dateStyles: dateStyles, uses1904: uses1904)
                if [nil, "n"].contains(cell.attributes["t"]), cell.child("f") == nil,
                   !dateStyles.contains(cell.attributes["s"].flatMap(Int.init) ?? -1), !fields[index].isEmpty {
                    numbers.insert(ImportNumericCell(row: records.count, column: index))
                }
            }
            if fields.contains(where: { !$0.isEmpty }) { records.append(fields) }
        }
        let width = records.map(\.count).max() ?? 0
        return WorksheetData(rows: records.map { $0 + Array(repeating: "", count: width - $0.count) }, numbers: numbers)
    }

    private static func column(_ reference: String?, fallback: Int) throws -> Int {
        guard let reference else {
            guard fallback < TransactionCSVImporter.maximumColumnCount else { throw CSVImportViewError.documentTooLarge }
            return fallback
        }
        let letters = reference.prefix(while: { $0.isLetter })
        guard !letters.isEmpty, reference.dropFirst(letters.count).allSatisfy(\.isNumber) else { throw CSVImportViewError.unsupportedDocument }
        var index = 0
        for char in letters.utf8 {
            guard (65...90).contains(char), index < 256 else { throw CSVImportViewError.unsupportedDocument }
            index = index * 26 + Int(char - 64)
        }
        guard index > 0, index <= TransactionCSVImporter.maximumColumnCount else { throw CSVImportViewError.documentTooLarge }
        return index - 1
    }

    private static func value(_ cell: XLSXXMLNode, strings: [String], dateStyles: Set<Int>, uses1904: Bool) throws -> String {
        if let formula = cell.child("f") { return "=" + formula.content }
        let text = cell.child("v")?.content ?? ""
        switch cell.attributes["t"] {
        case "s":
            guard let index = Int(text), strings.indices.contains(index) else { throw CSVImportViewError.unsupportedDocument }
            return strings[index]
        case "inlineStr": return cell.child("is")?.content ?? ""
        case "str", "d": return text
        case "b": return text == "1" ? "true" : "false"
        case "e": return "#ERROR " + text
        default:
            guard let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return text }
            if let style = cell.attributes["s"].flatMap(Int.init), dateStyles.contains(style) {
                return ImportDateEncoding.excelDate(number, uses1904: uses1904) ?? "#INVALID_DATE " + text
            }
            return NSDecimalNumber(decimal: number).stringValue
        }
    }
}
