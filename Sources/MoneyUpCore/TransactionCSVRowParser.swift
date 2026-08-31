import CryptoKit
import Foundation

extension TransactionCSVImporter {
    private struct RowValues {
        let columns: [String]
        let indexes: [Field: Int]

        func value(_ field: Field) -> String? {
            guard let index = indexes[field], columns.indices.contains(index) else {
                return nil
            }
            let cleaned = normalizedValue(columns[index])
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private struct ParsedRowAmounts {
        let kind: ImportedTransactionKind
        let amount: Decimal
        let destinationAmount: Decimal?
        let currencyCode: String?
    }

    private struct RowIdentity {
        let value: String
        let hasExternalID: Bool
        let legacyCandidates: Set<String>
    }

    static func parseRow(
        _ columns: [String],
        line: Int,
        indexes: [Field: Int],
        locale: Locale,
        timeZone: TimeZone
    ) throws -> ImportedTransaction {
        let row = RowValues(columns: columns, indexes: indexes)
        guard let dateText = row.value(.date),
              let occurredAt = parsedDate(dateText, locale: locale, timeZone: timeZone) else {
            throw RowError.invalidDate
        }
        let parsed = try parsedRowAmounts(row, locale: locale)
        let identity = rowIdentity(
            row,
            kind: parsed.kind,
            occurredAt: occurredAt,
            amount: parsed.amount,
            destinationAmount: parsed.destinationAmount,
            currencyCode: parsed.currencyCode
        )
        let semanticComponents = [
            row.value(.account), row.value(.destinationAccount), row.value(.category),
            row.value(.payee), row.value(.note)
        ]
        return ImportedTransaction(
            id: identity.value,
            hasExternalID: identity.hasExternalID,
            legacyFingerprintCandidates: identity.legacyCandidates,
            sourceLine: line,
            kind: parsed.kind,
            occurredAt: occurredAt,
            originContext: .capture(
                for: occurredAt,
                calendar: Calendar(identifier: .gregorian),
                timeZone: originTimeZone(from: dateText) ?? timeZone
            ),
            amount: parsed.amount,
            destinationAmount: parsed.destinationAmount,
            currencyCode: parsed.currencyCode,
            accountName: semanticComponents[0],
            destinationAccountName: semanticComponents[1],
            categoryName: semanticComponents[2],
            payee: semanticComponents[3],
            note: semanticComponents[4]
        )
    }

    private static func parsedRowAmounts(
        _ row: RowValues,
        locale: Locale
    ) throws -> ParsedRowAmounts {
        let kindText = row.value(.kind)
        let explicitKind = kindText.flatMap(importKind)
        if kindText != nil, explicitKind == nil { throw RowError.unsupportedType }
        let currencyCode = row.value(.currency)?.uppercased()
        let currency = currencyCode.flatMap { try? CurrencyCode($0) }
        let explicit = try validatedAmount(.amount, row: row, locale: locale, currency: currency)
        let outflow = try validatedAmount(.outflow, row: row, locale: locale, currency: currency)
        let inflow = try validatedAmount(.inflow, row: row, locale: locale, currency: currency)
        let nonzeroOutflow = outflow.map { abs($0) }.flatMap { $0 == .zero ? nil : $0 }
        let nonzeroInflow = inflow.map { abs($0) }.flatMap { $0 == .zero ? nil : $0 }
        guard nonzeroOutflow == nil || nonzeroInflow == nil else {
            throw RowError.invalidAmount
        }
        let direction = try resolvedKindAndAmount(
            explicitKind: explicitKind,
            explicitAmount: explicit,
            outflow: nonzeroOutflow,
            inflow: nonzeroInflow
        )
        return ParsedRowAmounts(
            kind: direction.0,
            amount: direction.1,
            destinationAmount: try destinationAmount(row, locale: locale),
            currencyCode: currencyCode
        )
    }

    private static func validatedAmount(
        _ field: Field,
        row: RowValues,
        locale: Locale,
        currency: CurrencyCode?
    ) throws -> Decimal? {
        guard let text = row.value(field) else { return nil }
        guard let parsed = parsedAmount(text, locale: locale),
              !parsed.isNaN,
              abs(parsed) <= MonetaryInputPolicy.maximumAbsoluteNewWrite,
              currency.map({ MonetaryInputPolicy.accepts(parsed, currency: $0) }) ?? true else {
            throw RowError.invalidAmount
        }
        return parsed
    }

    private static func resolvedKindAndAmount(
        explicitKind: ImportedTransactionKind?,
        explicitAmount: Decimal?,
        outflow: Decimal?,
        inflow: Decimal?
    ) throws -> (ImportedTransactionKind, Decimal) {
        guard let explicitKind else {
            if let outflow { return (.expense, outflow) }
            if let inflow { return (.income, inflow) }
            throw RowError.invalidAmount
        }
        let matchingFlow: Decimal?
        switch explicitKind {
        case .expense:
            guard inflow == nil else { throw RowError.invalidAmount }
            matchingFlow = outflow
        case .income, .refund:
            guard outflow == nil else { throw RowError.invalidAmount }
            matchingFlow = inflow
        case .transfer:
            matchingFlow = outflow ?? inflow
        }
        let normalizedExplicit = explicitAmount.map { abs($0) }
        if let normalizedExplicit, let matchingFlow, normalizedExplicit != matchingFlow {
            throw RowError.invalidAmount
        }
        guard let amount = normalizedExplicit ?? matchingFlow, amount != .zero else {
            throw RowError.invalidAmount
        }
        return (explicitKind, amount)
    }

    private static func destinationAmount(
        _ row: RowValues,
        locale: Locale
    ) throws -> Decimal? {
        guard let text = row.value(.destinationAmount) else { return nil }
        guard let parsed = parsedAmount(text, locale: locale),
              !parsed.isNaN,
              abs(parsed) > .zero,
              abs(parsed) <= MonetaryInputPolicy.maximumAbsoluteNewWrite else {
            throw RowError.invalidDestinationAmount
        }
        return abs(parsed)
    }

    private static func rowIdentity(
        _ row: RowValues,
        kind: ImportedTransactionKind,
        occurredAt: Date,
        amount: Decimal,
        destinationAmount: Decimal?,
        currencyCode: String?
    ) -> RowIdentity {
        let sourceID = row.value(.id)
        let common = [
            sourceID ?? "", kind.rawValue, ISO8601DateFormatter().string(from: occurredAt),
            NSDecimalNumber(decimal: amount).stringValue
        ]
        let semantic = common + [
            destinationAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "",
            currencyCode ?? "", humanFingerprintValue(row.value(.account)),
            humanFingerprintValue(row.value(.destinationAccount)),
            humanFingerprintValue(row.value(.category)), humanFingerprintValue(row.value(.payee)),
            humanFingerprintValue(row.value(.note))
        ]
        let legacySemantic = fingerprintV2(semantic)
        let identity = sourceID.map(externalIdentityFingerprint) ?? legacySemantic
        var legacyCandidates: Set<String> = [legacySemantic, legacyFNV1A64Fingerprint(
            common + [row.value(.currency) ?? "", row.value(.account) ?? "",
                      row.value(.destinationAccount) ?? "", row.value(.category) ?? "",
                      row.value(.payee) ?? "", row.value(.note) ?? ""]
        )]
        legacyCandidates.remove(identity)
        return RowIdentity(
            value: identity,
            hasExternalID: sourceID != nil,
            legacyCandidates: legacyCandidates
        )
    }

    static func importKind(_ value: String) -> ImportedTransactionKind? {
        switch normalizedHeader(value) {
        case "expense", "outflow", "支出", "消费", "付款": .expense
        case "income", "inflow", "收入", "收款": .income
        case "transfer", "转账", "转出", "还款", "转账/还款": .transfer
        case "refund", "reimbursement", "reimburse", "退款", "退货", "报销", "報銷": .refund
        default: nil
        }
    }

    static func parsedAmount(_ value: String, locale: Locale) -> Decimal? {
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

    static func isCurrencyDecoration(_ value: String) -> Bool {
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

    static func parsedDate(
        _ value: String,
        locale: Locale,
        timeZone: TimeZone
    ) -> Date? {
        let isoPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:[Zz]|[+-]\d{2}:\d{2})$"#
        if value.range(of: isoPattern, options: .regularExpression) != nil {
            let iso = ISO8601DateFormatter()
            iso.timeZone = timeZone
            if value.contains(".") {
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            }
            if let date = iso.date(from: value) { return date }
        }
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
            if let date = formatter.date(from: value),
               formatter.string(from: date) == value {
                return date
            }
        }
        return nil
    }

    static func prefersDayFirst(_ locale: Locale) -> Bool {
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

    static func originTimeZone(from value: String) -> TimeZone? {
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

    static func fieldIndexes(_ headers: [String]) -> [Field: Int] {
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

    static func normalizedHeader(_ value: String) -> String {
        normalizedValue(value)
            .lowercased()
            .replacingOccurrences(of: "[\\s_\\-（）()]+", with: "", options: .regularExpression)
    }

    static func normalizedValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func humanFingerprintValue(_ value: String?) -> String {
        (value ?? "")
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }

    /// Length-prefixed UTF-8 components prevent separator injection from
    /// making distinct rows hash identically. Only human labels are case-folded
    /// by the caller; external IDs retain their source-system casing.
    static func fingerprintV2(_ values: [String]) -> String {
        sha256Fingerprint(
            domain: "moneyup.csv.fingerprint.v2",
            values: values,
            prefix: "sha256:v2:"
        )
    }

    static func externalIdentityFingerprint(_ externalID: String) -> String {
        sha256Fingerprint(
            domain: "moneyup.csv.external-id.v1",
            values: [externalID],
            prefix: "sha256:external:v1:"
        )
    }

    static func sha256Fingerprint(
        domain: String,
        values: [String],
        prefix: String
    ) -> String {
        var data = Data(domain.utf8)
        data.append(0)
        for value in values {
            let bytes = Array(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { buffer in
                data.append(contentsOf: buffer)
            }
            data.append(contentsOf: bytes)
        }
        let digest = SHA256.hash(data: data)
        return prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compatibility with the importer shipped before SHA-256 identities.
    /// It is consulted only with a matching canonical source system.
    static func legacyFNV1A64Fingerprint(_ values: [String]) -> String {
        let bytes = values.joined(separator: "\u{1f}").lowercased().utf8
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "fnv1a64:\(String(hash, radix: 16))"
    }
}
