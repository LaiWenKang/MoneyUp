import CryptoKit
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
    public let originContext: TransactionOriginContext?
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
        originContext: TransactionOriginContext? = nil,
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
        self.originContext = originContext
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

public enum CSVImportMappedField: String, CaseIterable, Hashable, Identifiable, Sendable {
    case id, date, kind, amount, destinationAmount, currency
    case account, destinationAccount, category, payee, note, outflow, inflow

    public var id: String { rawValue }
}

public struct CSVColumnMapping: Equatable, Sendable {
    public var columns: [CSVImportMappedField: Int]

    public init(columns: [CSVImportMappedField: Int] = [:]) {
        self.columns = columns
    }

    public subscript(field: CSVImportMappedField) -> Int? {
        get { columns[field] }
        set { columns[field] = newValue }
    }

    public var hasRequiredColumns: Bool {
        columns[.date] != nil
            && (columns[.amount] != nil
                || columns[.outflow] != nil
                || columns[.inflow] != nil)
    }
}

public struct DelimitedImportInspection: Equatable, Sendable {
    public let headers: [String]
    public let sampleRows: [[String]]
    public let suggestedMapping: CSVColumnMapping

    public init(
        headers: [String],
        sampleRows: [[String]],
        suggestedMapping: CSVColumnMapping
    ) {
        self.headers = headers
        self.sampleRows = sampleRows
        self.suggestedMapping = suggestedMapping
    }
}

public enum TransactionCSVImportError: Error, Equatable, Sendable {
    case emptyFile
    case missingRequiredColumns
    case malformedCSV
    case tooManyRows
    case postingLevelExportRequiresArchive
}

/// Parses RFC 4180-style CSV/TSV exports using common English and Chinese
/// headers. The aliases include MoneyUp, generic, and Qianji-style labels; an
/// unknown row is reported for preview rather than guessed into the ledger.
public enum TransactionCSVImporter {
    private struct DelimitedRecord {
        let fields: [String]
        let sourceLine: Int
    }

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
    private static let isoCurrencyCodes = Set(
        Locale.Currency.isoCurrencies.map(\.identifier)
    )

    public static func parse(
        _ text: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) throws -> CSVImportPreview {
        let records = try parseRecords(text)
        guard let headers = records.first?.fields, !headers.isEmpty else {
            throw TransactionCSVImportError.emptyFile
        }
        let indexes = fieldIndexes(headers)
        return try preview(
            records: records,
            indexes: indexes,
            locale: locale,
            timeZone: timeZone
        )
    }

    public static func inspect(_ text: String) throws -> DelimitedImportInspection {
        let records = try parseRecords(text)
        guard let headers = records.first?.fields, !headers.isEmpty else {
            throw TransactionCSVImportError.emptyFile
        }
        let indexes = fieldIndexes(headers)
        return DelimitedImportInspection(
            headers: headers,
            sampleRows: records.dropFirst().prefix(5).map(\.fields),
            suggestedMapping: publicMapping(indexes)
        )
    }

    public static func parse(
        _ text: String,
        mapping: CSVColumnMapping,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) throws -> CSVImportPreview {
        let records = try parseRecords(text)
        guard records.first?.fields.isEmpty == false else {
            throw TransactionCSVImportError.emptyFile
        }
        return try preview(
            records: records,
            indexes: internalMapping(mapping),
            locale: locale,
            timeZone: timeZone
        )
    }

    private static func preview(
        records: [DelimitedRecord],
        indexes: [Field: Int],
        locale: Locale,
        timeZone: TimeZone
    ) throws -> CSVImportPreview {
        guard let headers = records.first?.fields else {
            throw TransactionCSVImportError.emptyFile
        }
        let normalizedHeaders = Set(headers.map(normalizedHeader))
        if normalizedHeaders.contains("entryid"),
           normalizedHeaders.contains("postingid") {
            throw TransactionCSVImportError.postingLevelExportRequiresArchive
        }
        guard indexes[.date] != nil,
              indexes[.amount] != nil || indexes[.outflow] != nil || indexes[.inflow] != nil else {
            throw TransactionCSVImportError.missingRequiredColumns
        }

        var rows: [ImportedTransaction] = []
        var issues: [CSVImportIssue] = []
        for record in records.dropFirst() {
            let columns = record.fields
            let line = record.sourceLine
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

    private static func publicMapping(_ indexes: [Field: Int]) -> CSVColumnMapping {
        CSVColumnMapping(
            columns: Dictionary(uniqueKeysWithValues: indexes.map { field, index in
                (publicField(field), index)
            })
        )
    }

    private static func internalMapping(_ mapping: CSVColumnMapping) -> [Field: Int] {
        Dictionary(uniqueKeysWithValues: mapping.columns.map { field, index in
            (internalField(field), index)
        })
    }

    private static func publicField(_ field: Field) -> CSVImportMappedField {
        switch field {
        case .id: .id
        case .date: .date
        case .kind: .kind
        case .amount: .amount
        case .destinationAmount: .destinationAmount
        case .currency: .currency
        case .account: .account
        case .destinationAccount: .destinationAccount
        case .category: .category
        case .payee: .payee
        case .note: .note
        case .outflow: .outflow
        case .inflow: .inflow
        }
    }

    private static func internalField(_ field: CSVImportMappedField) -> Field {
        switch field {
        case .id: .id
        case .date: .date
        case .kind: .kind
        case .amount: .amount
        case .destinationAmount: .destinationAmount
        case .currency: .currency
        case .account: .account
        case .destinationAccount: .destinationAccount
        case .category: .category
        case .payee: .payee
        case .note: .note
        case .outflow: .outflow
        case .inflow: .inflow
        }
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

        let kindText = value(.kind)
        let explicitKind = kindText.flatMap(importKind)
        if kindText != nil, explicitKind == nil {
            throw RowError.unsupportedType
        }

        func amount(_ field: Field) throws -> Decimal? {
            guard let text = value(field) else { return nil }
            guard let parsed = parsedAmount(text, locale: locale) else {
                throw RowError.invalidAmount
            }
            return parsed
        }

        let explicitAmount = try amount(.amount)
        let outflow = try amount(.outflow)
        let inflow = try amount(.inflow)
        let nonzeroOutflow = outflow.map { abs($0) }
            .flatMap { $0 == .zero ? nil : $0 }
        let nonzeroInflow = inflow.map { abs($0) }
            .flatMap { $0 == .zero ? nil : $0 }
        guard nonzeroOutflow == nil || nonzeroInflow == nil else {
            // A row cannot honestly be inferred as both money-in and
            // money-out. Make the user fix its mapping instead of silently
            // preferring one column.
            throw RowError.invalidAmount
        }

        let kind: ImportedTransactionKind
        let amount: Decimal
        if let explicitKind {
            kind = explicitKind
            let matchingFlow: Decimal?
            switch explicitKind {
            case .expense:
                guard nonzeroInflow == nil else { throw RowError.invalidAmount }
                matchingFlow = nonzeroOutflow
            case .income, .refund:
                guard nonzeroOutflow == nil else { throw RowError.invalidAmount }
                matchingFlow = nonzeroInflow
            case .transfer:
                matchingFlow = nonzeroOutflow ?? nonzeroInflow
            }
            let normalizedExplicit = explicitAmount.map { abs($0) }
            if let normalizedExplicit, let matchingFlow,
               normalizedExplicit != matchingFlow {
                throw RowError.invalidAmount
            }
            guard let parsed = normalizedExplicit ?? matchingFlow,
                  parsed != .zero else { throw RowError.invalidAmount }
            amount = parsed
        } else if let nonzeroOutflow {
            kind = .expense
            amount = nonzeroOutflow
        } else if let nonzeroInflow {
            kind = .income
            amount = nonzeroInflow
        } else {
            throw RowError.invalidAmount
        }

        let destinationAmount = try amount(.destinationAmount).map { abs($0) }
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
            originContext: .capture(
                for: occurredAt,
                calendar: Calendar(identifier: .gregorian),
                timeZone: originTimeZone(from: dateText) ?? timeZone
            ),
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
        guard value.utf8.count <= 128 else { return nil }
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var isParenthesizedNegative = false
        if text.first == "(" || text.last == ")" {
            guard text.first == "(", text.last == ")" else { return nil }
            isParenthesizedNegative = true
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var sign: Decimal = 1
        var hasLeadingSign = false
        if text.first == "+" || text.first == "-" {
            guard !isParenthesizedNegative else { return nil }
            hasLeadingSign = true
            if text.first == "-" { sign = -1 }
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }

        guard let firstDigit = text.firstIndex(where: \.isNumber),
              let lastDigit = text.lastIndex(where: \.isNumber) else {
            return nil
        }
        var prefix = String(text[..<firstDigit])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let numericEnd = text.index(after: lastDigit)
        let suffix = String(text[numericEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var number = String(text[firstDigit..<numericEnd])

        // Some exports put the sign between a currency symbol and the number
        // (for example `$-12.50`). It is still accepted only when every other
        // character is a recognized currency decoration.
        if prefix.last == "+" || prefix.last == "-" {
            guard !hasLeadingSign, !isParenthesizedNegative else { return nil }
            if prefix.last == "-" { sign = -1 }
            prefix.removeLast()
            prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard prefix.isEmpty || suffix.isEmpty,
              isCurrencyDecoration(prefix),
              isCurrencyDecoration(suffix) else {
            return nil
        }

        let parsed: Decimal?
        if let local = TextScanner.decimal(from: number, locale: locale) {
            parsed = local
        } else {
            // Imports often come from a device with a different locale. Only
            // use the alternate separator when the token contains one
            // separator kind; mixed separators remain locale-dependent.
            let decimalSeparator = locale.decimalSeparator ?? "."
            let alternate = decimalSeparator == "." ? "," : "."
            guard number.contains(alternate),
                  !number.contains(decimalSeparator) else { return nil }
            let parts = number.components(separatedBy: alternate)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty,
                  parts[0].allSatisfy(\.isNumber),
                  parts[1].allSatisfy(\.isNumber) else { return nil }
            number = parts[0] + "." + parts[1]
            parsed = Decimal(
                string: number,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        guard let parsed else { return nil }
        let effectiveSign: Decimal = isParenthesizedNegative ? -1 : sign
        return parsed * effectiveSign
    }

    private static func isCurrencyDecoration(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        let uppercased = value.uppercased()
        if isoCurrencyCodes.contains(uppercased) {
            return true
        }
        let commonSymbols: Set<String> = [
            "RM", "RMB", "US$", "S$", "HK$", "A$", "C$", "NZ$", "CN¥", "JP¥"
        ]
        if commonSymbols.contains(uppercased) { return true }
        return value.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .currencySymbol
        }
    }

    private static func parsedDate(
        _ value: String,
        locale: Locale,
        timeZone: TimeZone
    ) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        if let date = iso.date(from: value) { return date }
        let fixedFormats = [
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
            "yyyy.MM.dd HH:mm:ss", "yyyy.MM.dd HH:mm", "yyyy.MM.dd"
        ]
        let dayFirstFormats = ["/", "-", "."].flatMap { separator in
            [
                "dd\(separator)MM\(separator)yyyy HH:mm:ss",
                "dd\(separator)MM\(separator)yyyy HH:mm",
                "dd\(separator)MM\(separator)yyyy"
            ]
        }
        let monthFirstFormats = ["/", "-", "."].flatMap { separator in
            [
                "MM\(separator)dd\(separator)yyyy HH:mm:ss",
                "MM\(separator)dd\(separator)yyyy HH:mm",
                "MM\(separator)dd\(separator)yyyy"
            ]
        }
        let formats = fixedFormats + (prefersDayFirst(locale)
            ? dayFirstFormats + monthFirstFormats
            : monthFirstFormats + dayFirstFormats)
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

    private static func prefersDayFirst(_ locale: Locale) -> Bool {
        guard let format = DateFormatter.dateFormat(
            fromTemplate: "yMd",
            options: 0,
            locale: locale
        ),
        let day = format.firstIndex(of: "d"),
        let month = format.firstIndex(of: "M") else {
            return false
        }
        return day < month
    }

    private static func originTimeZone(from value: String) -> TimeZone? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("Z") || trimmed.hasSuffix("z") {
            return TimeZone(secondsFromGMT: 0)
        }
        guard let match = trimmed.range(
            of: #"([+-])(\d{2}):?(\d{2})$"#,
            options: .regularExpression
        ) else { return nil }
        let suffix = String(trimmed[match])
        let sign = suffix.first == "-" ? -1 : 1
        let digits = suffix.dropFirst().filter(\.isNumber)
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              hours <= 23,
              minutes <= 59 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
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
        let data = Data(
            values.joined(separator: "\u{1f}").lowercased().utf8
        )
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func parseRecords(_ text: String) throws -> [DelimitedRecord] {
        guard !text.isEmpty else { throw TransactionCSVImportError.emptyFile }
        let delimiter: Character
        let candidates: [Character] = [",", "\t", ";"]
        delimiter = candidates.max { left, right in
            delimiterCount(left, inFirstRecordOf: text)
                < delimiterCount(right, inFirstRecordOf: text)
        } ?? ","

        var records: [DelimitedRecord] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var closedQuotedField = false
        var index = text.startIndex
        var physicalLine = 1
        var recordStartLine = 1

        func appendCurrentRecord() throws {
            // The AppModel enforces the same aggregate write budget. Enforce
            // it while parsing too, before an oversized preview can allocate
            // an unbounded array of row models.
            guard records.count < MonetaryInputPolicy.aggregateRecordBudget + 1 else {
                throw TransactionCSVImportError.tooManyRows
            }
            records.append(DelimitedRecord(
                fields: record,
                sourceLine: recordStartLine
            ))
        }

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
                    closedQuotedField = true
                } else {
                    field.append(character)
                    if character == "\n"
                        || (character == "\r"
                            && (next == text.endIndex || text[next] != "\n")) {
                        physicalLine += 1
                    }
                }
            } else if closedQuotedField {
                if character == delimiter {
                    record.append(field)
                    field = ""
                    closedQuotedField = false
                } else if character == "\n" || character == "\r" {
                    record.append(field)
                    field = ""
                    try appendCurrentRecord()
                    record = []
                    closedQuotedField = false
                    physicalLine += 1
                    recordStartLine = physicalLine
                    if character == "\r", next < text.endIndex, text[next] == "\n" {
                        index = text.index(after: next)
                        continue
                    }
                } else {
                    throw TransactionCSVImportError.malformedCSV
                }
            } else if character == "\"" {
                guard field.isEmpty else {
                    throw TransactionCSVImportError.malformedCSV
                }
                inQuotes = true
            } else if character == delimiter {
                record.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                record.append(field)
                field = ""
                try appendCurrentRecord()
                record = []
                physicalLine += 1
                recordStartLine = physicalLine
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
        if !field.isEmpty || !record.isEmpty || closedQuotedField {
            record.append(field)
            try appendCurrentRecord()
        }
        return records
    }

    private static func delimiterCount(
        _ delimiter: Character,
        inFirstRecordOf text: String
    ) -> Int {
        var count = 0
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if inQuotes, next < text.endIndex, text[next] == "\"" {
                    index = text.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if !inQuotes, character == delimiter {
                count += 1
            } else if !inQuotes, character == "\n" || character == "\r" {
                break
            }
            index = next
        }
        return count
    }
}
