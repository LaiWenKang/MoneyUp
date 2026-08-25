import Foundation

public enum ImportedTransactionKind: String, Sendable {
    case expense
    case income
    case transfer
    case refund
}

public struct ImportedTransaction: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceLine: Int
    public let kind: ImportedTransactionKind
    public let occurredAt: Date
    public let amount: Decimal
    public let destinationAmount: Decimal?
    public let currencyCode: String?
    public let accountName: String?
    public let destinationAccountName: String?
    public let categoryName: String?
    public let payee: String?
    public let note: String?

    public init(
        id: String,
        sourceLine: Int,
        kind: ImportedTransactionKind,
        occurredAt: Date,
        amount: Decimal,
        destinationAmount: Decimal? = nil,
        currencyCode: String? = nil,
        accountName: String? = nil,
        destinationAccountName: String? = nil,
        categoryName: String? = nil,
        payee: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.sourceLine = sourceLine
        self.kind = kind
        self.occurredAt = occurredAt
        self.amount = amount
        self.destinationAmount = destinationAmount
        self.currencyCode = currencyCode
        self.accountName = accountName
        self.destinationAccountName = destinationAccountName
        self.categoryName = categoryName
        self.payee = payee
        self.note = note
    }
}

public struct CSVImportIssue: Equatable, Sendable, Identifiable {
    public let line: Int
    public let reason: String
    public var id: String { "\(line):\(reason)" }

    public init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }
}

public struct CSVImportPreview: Equatable, Sendable {
    public let rows: [ImportedTransaction]
    public let issues: [CSVImportIssue]

    public init(rows: [ImportedTransaction], issues: [CSVImportIssue]) {
        self.rows = rows
        self.issues = issues
    }
}

public enum TransactionCSVImportError: Error, Equatable, Sendable {
    case emptyFile
    case missingRequiredColumns
    case malformedCSV
    case postingLevelExportRequiresArchive
}

/// Parses RFC 4180-style CSV/TSV exports using common English and Chinese
/// headers. The aliases include MoneyUp, generic, and Qianji-style labels; an
/// unknown row is reported for preview rather than guessed into the ledger.
public enum TransactionCSVImporter {
    private enum Field: Hashable {
        case id, date, kind, amount, destinationAmount, currency
        case account, destinationAccount, category, payee, note, outflow, inflow
    }

    private static let aliases: [Field: [String]] = [
        .id: ["id", "transactionid", "账单id", "交易id", "订单号", "交易单号"],
        .date: ["date", "time", "datetime", "日期", "时间", "账单日期", "账单时间", "交易时间", "创建时间"],
        .kind: ["type", "kind", "transactiontype", "类型", "账单类型", "收支类型", "交易类型"],
        .amount: ["amount", "value", "金额", "账单金额", "实际金额", "交易金额"],
        .destinationAmount: ["destinationamount", "receivedamount", "转入金额", "到账金额"],
        .currency: ["currency", "currencycode", "币种", "货币"],
        .account: ["account", "fromaccount", "账户", "账户1", "资产", "资产账户", "付款账户", "转出账户"],
        .destinationAccount: ["toaccount", "destinationaccount", "账户2", "目标账户", "转入账户", "收款账户"],
        .category: ["subcategory", "category", "二级分类", "分类", "一级分类"],
        .payee: ["payee", "merchant", "counterparty", "商家", "商户", "交易对象", "交易对方", "项目"],
        .note: ["memo", "note", "remark", "备注", "说明", "标签"],
        .outflow: ["outflow", "支出金额"],
        .inflow: ["inflow", "收入金额"]
    ]

    public static func parse(
        _ text: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) throws -> CSVImportPreview {
        let records = try parseRecords(text)
        guard let headers = records.first, !headers.isEmpty else {
            throw TransactionCSVImportError.emptyFile
        }
        let normalizedHeaders = Set(headers.map(normalizedHeader))
        if normalizedHeaders.contains("entryid"),
           normalizedHeaders.contains("postingid") {
            throw TransactionCSVImportError.postingLevelExportRequiresArchive
        }
        let indexes = fieldIndexes(headers)
        guard indexes[.date] != nil,
              indexes[.amount] != nil || indexes[.outflow] != nil || indexes[.inflow] != nil else {
            throw TransactionCSVImportError.missingRequiredColumns
        }

        var rows: [ImportedTransaction] = []
        var issues: [CSVImportIssue] = []
        for (offset, columns) in records.dropFirst().enumerated() {
            let line = offset + 2
            if columns.allSatisfy({ normalizedValue($0).isEmpty }) { continue }
            do {
                rows.append(
                    try parseRow(
                        columns,
                        line: line,
                        indexes: indexes,
                        locale: locale,
                        timeZone: timeZone
                    )
                )
            } catch let issue as RowError {
                issues.append(CSVImportIssue(line: line, reason: issue.rawValue))
            } catch {
                issues.append(CSVImportIssue(line: line, reason: "invalid_row"))
            }
        }
        return CSVImportPreview(rows: rows, issues: issues)
    }

    private enum RowError: String, Error {
        case invalidDate = "invalid_date"
        case invalidAmount = "invalid_amount"
        case unsupportedType = "unsupported_type"
    }

    private static func parseRow(
        _ columns: [String],
        line: Int,
        indexes: [Field: Int],
        locale: Locale,
        timeZone: TimeZone
    ) throws -> ImportedTransaction {
        func value(_ field: Field) -> String? {
            guard let index = indexes[field], columns.indices.contains(index) else { return nil }
            let cleaned = normalizedValue(columns[index])
            return cleaned.isEmpty ? nil : cleaned
        }

        guard let dateText = value(.date),
              let occurredAt = parsedDate(dateText, locale: locale, timeZone: timeZone) else {
            throw RowError.invalidDate
        }

        let explicitKind = value(.kind).flatMap(importKind)
        let outflow = value(.outflow).flatMap { parsedAmount($0, locale: locale) }
        let inflow = value(.inflow).flatMap { parsedAmount($0, locale: locale) }
        let kind: ImportedTransactionKind
        let amount: Decimal
        if let explicitKind {
            kind = explicitKind
            guard let parsed = value(.amount).flatMap({ parsedAmount($0, locale: locale) }),
                  parsed != .zero else { throw RowError.invalidAmount }
            amount = abs(parsed)
        } else if let outflow, outflow != .zero {
            kind = .expense
            amount = abs(outflow)
        } else if let inflow, inflow != .zero {
            kind = .income
            amount = abs(inflow)
        } else if value(.kind) != nil {
            throw RowError.unsupportedType
        } else {
            throw RowError.invalidAmount
        }

        let destinationAmount = value(.destinationAmount)
            .flatMap { parsedAmount($0, locale: locale) }
            .map { abs($0) }
        let sourceID = value(.id)
        let identity = fingerprint([
            sourceID ?? "",
            kind.rawValue,
            ISO8601DateFormatter().string(from: occurredAt),
            NSDecimalNumber(decimal: amount).stringValue,
            value(.currency) ?? "",
            value(.account) ?? "",
            value(.destinationAccount) ?? "",
            value(.category) ?? "",
            value(.payee) ?? "",
            value(.note) ?? ""
        ])

        return ImportedTransaction(
            id: identity,
            sourceLine: line,
            kind: kind,
            occurredAt: occurredAt,
            amount: amount,
            destinationAmount: destinationAmount,
            currencyCode: value(.currency)?.uppercased(),
            accountName: value(.account),
            destinationAccountName: value(.destinationAccount),
            categoryName: value(.category),
            payee: value(.payee),
            note: value(.note)
        )
    }

    private static func importKind(_ value: String) -> ImportedTransactionKind? {
        switch normalizedHeader(value) {
        case "expense", "outflow", "支出", "消费", "付款": .expense
        case "income", "inflow", "收入", "收款": .income
        case "transfer", "转账", "转出", "还款", "转账/还款": .transfer
        case "refund", "reimbursement", "reimburse", "退款", "退货", "报销", "報銷": .refund
        default: nil
        }
    }

    private static func parsedAmount(_ value: String, locale: Locale) -> Decimal? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(
            of: "[^0-9+,.\\-]",
            with: "",
            options: .regularExpression
        )
        guard !text.isEmpty else { return nil }
        if text.first == "+" || text.first == "-" {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }

        if let local = TextScanner.decimal(from: text, locale: locale) {
            return local
        }

        // Imports often come from a device with a different locale. Only use
        // the alternate separator when the token contains one separator kind;
        // mixed separators remain locale-dependent and are rejected if invalid.
        let decimalSeparator = locale.decimalSeparator ?? "."
        let alternate = decimalSeparator == "." ? "," : "."
        guard text.contains(alternate), !text.contains(decimalSeparator) else { return nil }
        let parts = text.components(separatedBy: alternate)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[0].allSatisfy(\.isNumber),
              parts[1].allSatisfy(\.isNumber) else { return nil }
        return Decimal(
            string: parts[0] + "." + parts[1],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func parsedDate(
        _ value: String,
        locale: Locale,
        timeZone: TimeZone
    ) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        if let date = iso.date(from: value) { return date }
        let formats = [
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
            "yyyy.MM.dd HH:mm:ss", "yyyy.MM.dd HH:mm", "yyyy.MM.dd",
            "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy",
            "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm", "MM/dd/yyyy"
        ]
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.isLenient = false
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func fieldIndexes(_ headers: [String]) -> [Field: Int] {
        let normalized = headers.map(normalizedHeader)
        var result: [Field: Int] = [:]
        for (field, candidates) in aliases {
            for candidate in candidates {
                if let index = normalized.firstIndex(of: normalizedHeader(candidate)) {
                    result[field] = index
                    break
                }
            }
        }
        return result
    }

    private static func normalizedHeader(_ value: String) -> String {
        normalizedValue(value)
            .lowercased()
            .replacingOccurrences(of: "[\\s_\\-（）()]+", with: "", options: .regularExpression)
    }

    private static func normalizedValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fingerprint(_ values: [String]) -> String {
        let bytes = values.joined(separator: "\u{1f}").lowercased().utf8
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "fnv1a64:\(String(hash, radix: 16))"
    }

    private static func parseRecords(_ text: String) throws -> [[String]] {
        guard !text.isEmpty else { throw TransactionCSVImportError.emptyFile }
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let delimiter: Character
        let candidates: [Character] = [",", "\t", ";"]
        delimiter = candidates.max { left, right in
            firstLine.filter { $0 == left }.count < firstLine.filter { $0 == right }.count
        } ?? ","

        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == delimiter {
                record.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                record.append(field)
                field = ""
                records.append(record)
                record = []
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                    continue
                }
            } else {
                field.append(character)
            }
            index = next
        }
        guard !inQuotes else { throw TransactionCSVImportError.malformedCSV }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}
