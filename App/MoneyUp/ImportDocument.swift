import Foundation
import MoneyUpCore

struct ImportNumericCell: Hashable, Sendable {
    let row: Int
    let column: Int
}

struct ImportDataTable: Identifiable, Sendable {
    let id: String
    let name: String
    let rows: [[String]]
    var originalText: String? = nil
    var numericCells: Set<ImportNumericCell> = []

    static func populatedColumns(_ rows: [[String]]) -> [Int] {
        let width = rows.map(\.count).max() ?? 0
        return (0..<width).filter { column in rows.contains { $0.indices.contains(column) && !$0[column].isEmpty } }
    }

    static func normalizedRows(_ rows: [[String]]) -> [[String]] {
        guard let first = rows.first else { return [] }
        let columns = populatedColumns(rows)
        let names = columns.map { first.indices.contains($0) ? first[$0].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        let headers = zip(columns, names).map { column, name in
            let suffix = "[\(column + 1)]"
            return name.isEmpty ? suffix : (counts[name, default: 0] > 1 ? name + " " + suffix : name)
        }
        return [headers] + rows.dropFirst().map { row in columns.map { row.indices.contains($0) ? row[$0] : "" } }
    }

    func csv(mapping: CSVColumnMapping? = nil, dateEncoding: ImportDateEncoding = .text,
             qianjiTypes: Bool = false, typeOverrides: [String: String] = [:], locale: Locale = .current) throws -> String {
        if dateEncoding == .text, !qianjiTypes, typeOverrides.isEmpty, let originalText { return originalText }
        var records = rows
        let numericMapping = try mapping ?? TransactionCSVImporter.inspect(Self.csv(Array(rows.prefix(1)))).suggestedMapping
        let monetaryColumns = Set([CSVImportMappedField.amount, .destinationAmount, .outflow, .inflow].compactMap { numericMapping[$0] })
        for cell in numericCells where monetaryColumns.contains(cell.column) && records.indices.contains(cell.row) && records[cell.row].indices.contains(cell.column) {
            records[cell.row][cell.column] = records[cell.row][cell.column].replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
        }
        if let mapping {
            for index in records.indices.dropFirst() {
                if let column = mapping[.date], records[index].indices.contains(column), dateEncoding != .text {
                    records[index][column] = dateEncoding.convert(records[index][column]) ?? "#INVALID_DATE " + records[index][column]
                }
                if let column = mapping[.kind], records[index].indices.contains(column) {
                    let original = records[index][column].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let replacement = typeOverrides[original] { records[index][column] = replacement }
                    else if qianjiTypes {
                        // Qianji's reimbursement original is an advance, not a
                        // receipt of cash. Code 5 stays review-only until mapped.
                        records[index][column] = ["0": "expense", "1": "income", "2": "transfer", "3": "transfer"][original] ?? original
                    }
                }
            }
        }
        return try Self.csv(records)
    }

    static func csv(_ rows: [[String]]) throws -> String {
        guard rows.count <= 20_001 else { throw TransactionCSVImportError.tooManyRows }
        var output = ""
        for row in rows {
            guard row.count <= TransactionCSVImporter.maximumColumnCount else { throw TransactionCSVImportError.inputTooLarge }
            for (index, cell) in row.enumerated() {
                guard cell.utf8.count <= TransactionCSVImporter.maximumFieldByteCount else { throw TransactionCSVImportError.inputTooLarge }
                guard !cell.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value)
                }) else { throw CSVImportViewError.unsupportedDocument }
                if index > 0 { output.append(",") }
                output.append("\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            }
            output.append("\n")
            guard output.utf8.count <= TransactionCSVImporter.maximumInputByteCount else { throw TransactionCSVImportError.inputTooLarge }
        }
        return output
    }
}

enum ImportDateEncoding: String, CaseIterable, Identifiable {
    case text, unixSeconds, unixMilliseconds, excel1900, excel1904
    var id: String { rawValue }
    var titleKey: String { "import.date_encoding." + rawValue }

    func convert(_ text: String) -> String? {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN,
              text.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        switch self {
        case .text: return text
        case .unixSeconds, .unixMilliseconds:
            let seconds = NSDecimalNumber(decimal: self == .unixMilliseconds ? value / 1000 : value).doubleValue
            guard seconds.isFinite, abs(seconds) < 253_402_300_799 else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        case .excel1900, .excel1904:
            return Self.excelDate(value, uses1904: self == .excel1904)
        }
    }

    static func excelDate(_ value: Decimal, uses1904: Bool) -> String? {
        guard value >= 0, value < 2_958_466, uses1904 || value < 60 || value >= 61 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = zone
        guard let epoch = calendar.date(from: DateComponents(year: uses1904 ? 1904 : 1899,
            month: uses1904 ? 1 : 12, day: uses1904 ? 1 : 31)) else { return nil }
        let days = !uses1904 && value >= 61 ? value - 1 : value
        let date = epoch.addingTimeInterval(NSDecimalNumber(decimal: days * 86_400).doubleValue)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

struct ImportDocument: Sendable {
    let tables: [ImportDataTable]
    let sourceText: String?

    static func decode(_ data: Data) throws -> ImportDocument {
        guard data.count <= TransactionCSVImporter.maximumInputByteCount else { throw AppModelError.importTooLarge }
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
            return ImportDocument(tables: try XLSXImportReader.tables(data), sourceText: nil)
        }
        let text = try DelimitedImportFile.decode(data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "[" || trimmed.first == "{" {
            do { return ImportDocument(tables: try JSONImportReader.tables(Data(trimmed.utf8)), sourceText: nil) }
            catch is DecodingError { throw CSVImportViewError.unsupportedDocument }
        }
        let rows = try TransactionCSVImporter.tableRows(text)
        return ImportDocument(tables: [ImportDataTable(id: "text", name: "CSV / TSV", rows: rows, originalText: text)], sourceText: text)
    }
}
