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
    /// `true` only when the source file supplied a non-empty transaction ID.
    /// Callers can use this to prefer the source system's stable identity over
    /// weaker semantic matching without exposing the original ID in storage.
    public let hasExternalID: Bool
    /// Previous unscoped importer identities for a same-source migration
    /// check. These are hashes only; the external source ID is never retained.
    public let legacyFingerprintCandidates: Set<String>
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
        hasExternalID: Bool = false,
        legacyFingerprintCandidates: Set<String> = [],
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
        self.hasExternalID = hasExternalID
        self.legacyFingerprintCandidates = legacyFingerprintCandidates
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
        guard columns.values.allSatisfy({ $0 >= 0 }),
              Set(columns.values).count == columns.count,
              columns[.date] != nil else {
            return false
        }
        let hasDirectionalAmount = columns[.outflow] != nil
            || columns[.inflow] != nil
        // A generic Amount column carries no direction by itself. It is only
        // actionable when a Type/Kind column is also mapped; directional
        // outflow/inflow columns can infer the kind without one.
        return hasDirectionalAmount
            || (columns[.amount] != nil && columns[.kind] != nil)
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
    case inputTooLarge
    case tooManyRows
    case postingLevelExportRequiresArchive
}

/// Parses RFC 4180-style CSV/TSV exports using common English and Chinese
/// headers. The aliases include MoneyUp, generic, and Qianji-style labels; an
/// unknown row is reported for preview rather than guessed into the ledger.
public enum TransactionCSVImporter {
    /// Mirrors the file-picker boundary, but is enforced here as well because
    /// the core parser is also callable by tests and future non-UI clients.
    public static let maximumInputByteCount = 10_000_000
    public static let maximumColumnCount = 256
    public static let maximumHeaderByteCount = 256
    public static let maximumFieldByteCount = 4_096

    /// Canonical identity used only for namespacing persisted import hashes.
    /// User-facing `JournalEntry.sourceSystem` text remains unchanged.
    public static func canonicalSourceSystem(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .precomposedStringWithCanonicalMapping
    }

    /// Wraps a row identity in its canonical source namespace before it is
    /// stored in the journal index. Identical vendor IDs from two banks or
    /// import adapters therefore cannot suppress one another.
    public static func persistenceFingerprint(
        for transactionIdentity: String,
        sourceSystem: String
    ) -> String {
        sha256Fingerprint(
            domain: "moneyup.import.persistence.v1",
            values: [canonicalSourceSystem(sourceSystem), transactionIdentity],
            prefix: "sha256:import:v1:"
        )
    }

    struct DelimitedRecord {
        let fields: [String]
        let sourceLine: Int
    }

    enum Field: Hashable {
        case id, date, kind, amount, destinationAmount, currency
        case account, destinationAccount, category, payee, note, outflow, inflow
    }

    static let aliases: [Field: [String]] = [
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
    static let isoCurrencyCodes = Set(
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

    static func preview(
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
        guard indexes.values.allSatisfy({ headers.indices.contains($0) }),
              Set(indexes.values).count == indexes.count,
              hasRequiredFields(indexes) else {
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

    static func publicMapping(_ indexes: [Field: Int]) -> CSVColumnMapping {
        CSVColumnMapping(
            columns: Dictionary(uniqueKeysWithValues: indexes.map { field, index in
                (publicField(field), index)
            })
        )
    }

    static func internalMapping(_ mapping: CSVColumnMapping) -> [Field: Int] {
        Dictionary(uniqueKeysWithValues: mapping.columns.map { field, index in
            (internalField(field), index)
        })
    }

    static func hasRequiredFields(_ indexes: [Field: Int]) -> Bool {
        guard indexes[.date] != nil else { return false }
        let hasDirectionalAmount = indexes[.outflow] != nil
            || indexes[.inflow] != nil
        return hasDirectionalAmount
            || (indexes[.amount] != nil && indexes[.kind] != nil)
    }

    static func publicField(_ field: Field) -> CSVImportMappedField {
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

    static func internalField(_ field: CSVImportMappedField) -> Field {
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

    enum RowError: String, Error {
        case invalidDate = "invalid_date"
        case invalidAmount = "invalid_amount"
        case invalidDestinationAmount = "invalid_destination_amount"
        case unsupportedType = "unsupported_type"
    }
}
