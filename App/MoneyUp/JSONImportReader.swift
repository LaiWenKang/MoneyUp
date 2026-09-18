import Foundation
import MoneyUpCore

private indirect enum ImportJSONValue: Decodable {
    case text(String), number(Decimal), boolean(Bool), null
    case object([String: ImportJSONValue]), array([ImportJSONValue])

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 16 else { throw CSVImportViewError.unsupportedDocument }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .boolean(item) }
        else if let item = try? value.decode(String.self) { self = .text(item) }
        else if let item = try? value.decode(Decimal.self) { self = .number(item) }
        else if let items = try? value.decode([String: ImportJSONValue].self) { self = .object(items) }
        else { self = .array(try value.decode([ImportJSONValue].self)) }
    }

    func scalar() throws -> String {
        switch self {
        case let .text(value): value
        case let .number(value): NSDecimalNumber(decimal: value).stringValue
        case let .boolean(value): value ? "true" : "false"
        case .null: ""
        default: throw CSVImportViewError.unsupportedDocument
        }
    }
}

enum JSONImportReader {
    static func tables(_ data: Data) throws -> [ImportDataTable] {
        guard data.count <= TransactionCSVImporter.maximumInputByteCount else { throw AppModelError.importTooLarge }
        try validateDepthAndNumberPrecision(data)
        let root = try JSONDecoder().decode(ImportJSONValue.self, from: data)
        var tables: [ImportDataTable] = []
        try collect(root, path: "$", into: &tables)
        guard !tables.isEmpty, tables.count <= 32 else { throw CSVImportViewError.unsupportedDocument }
        return tables
    }

    private static func validateDepthAndNumberPrecision(_ data: Data) throws {
        let bytes = Array(data)
        var index = 0, depth = 0
        var quoted = false, escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 91 || byte == 123 {
                depth += 1
                guard depth <= 16 else { throw CSVImportViewError.unsupportedDocument }
            } else if byte == 93 || byte == 125 { depth -= 1 }
            else if (48...57).contains(byte) || byte == 45 {
                var digits = 0
                while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125, 58].contains(bytes[index]) {
                    if (48...57).contains(bytes[index]) { digits += 1 }
                    index += 1
                }
                guard digits <= 38 else { throw CSVImportViewError.unsupportedDocument }
                continue
            }
            index += 1
        }
    }

    private static func collect(_ value: ImportJSONValue, path: String, into tables: inout [ImportDataTable]) throws {
        guard tables.count <= 32 else { throw CSVImportViewError.unsupportedDocument }
        switch value {
        case let .array(items):
            guard !items.isEmpty, items.count <= 20_000 else { throw CSVImportViewError.unsupportedDocument }
            let objects = items.filter { if case .object = $0 { true } else { false } }
            if objects.isEmpty, path != "$" { return }
            guard objects.count == items.count else { throw CSVImportViewError.unsupportedDocument }
            var records: [[String: String]] = []
            var numberKeys: [Set<String>] = []
            for item in items {
                guard case let .object(fields) = item else { throw CSVImportViewError.unsupportedDocument }
                var record: [String: String] = [:]
                var numbers: Set<String> = []
                try flatten(fields, prefix: "", into: &record, numbers: &numbers)
                records.append(record)
                numberKeys.append(numbers)
            }
            let headers = Set(records.flatMap { $0.keys }).sorted()
            guard !headers.isEmpty, headers.count <= TransactionCSVImporter.maximumColumnCount else { throw CSVImportViewError.unsupportedDocument }
            let rows = [headers] + records.map { record in headers.map { record[$0] ?? "" } }
            let columns = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element, $0.offset) })
            let numeric = Set(numberKeys.enumerated().flatMap { row, keys in
                keys.compactMap { key in columns[key].map { ImportNumericCell(row: row + 1, column: $0) } }
            })
            _ = try ImportDataTable.csv(rows)
            tables.append(ImportDataTable(id: path, name: path == "$" ? "JSON" : String(path.dropFirst(2)), rows: rows, numericCells: numeric))
        case let .object(fields):
            if path == "$", fields.values.allSatisfy({ value in
                switch value { case .array, .object: false; default: true }
            }) {
                try collect(.array([value]), path: path, into: &tables)
                return
            }
            for key in fields.keys.sorted() {
                guard let child = fields[key] else { continue }
                switch child {
                case let .array(items) where items.isEmpty: continue
                case .array, .object: try collect(child, path: path + "." + key, into: &tables)
                default: continue
                }
            }
        default: throw CSVImportViewError.unsupportedDocument
        }
    }

    private static func flatten(_ fields: [String: ImportJSONValue], prefix: String, into record: inout [String: String], numbers: inout Set<String>) throws {
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            let name = prefix.isEmpty ? key : prefix + "." + key
            guard name.utf8.count <= TransactionCSVImporter.maximumHeaderByteCount,
                  record.count <= TransactionCSVImporter.maximumColumnCount else { throw CSVImportViewError.unsupportedDocument }
            if case let .object(nested) = value {
                try flatten(nested, prefix: name, into: &record, numbers: &numbers)
            } else if case let .array(items) = value {
                if items.isEmpty { record[name] = "" }
                else if ["tags", "labels", "images", "attachments"].contains(key.lowercased()) {
                    record[name] = try items.map { try $0.scalar() }.joined(separator: " · ")
                } else {
                    // Nonempty financial subrecords must not silently lose legs.
                    throw CSVImportViewError.unsupportedDocument
                }
            } else {
                guard record[name] == nil else { throw CSVImportViewError.unsupportedDocument }
                record[name] = try value.scalar()
                if case .number = value { numbers.insert(name) }
            }
        }
    }
}
