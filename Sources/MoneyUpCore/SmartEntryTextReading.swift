import Foundation

/// A semicolon explicitly separates description from financial input. Numbers,
/// dates and income/refund words inside a note cannot alter the transaction.
struct SmartEntryTextParts {
    let phrase: String
    let note: String?

    init(_ text: String) {
        let separator = text.firstIndex { $0 == ";" || $0 == "；" }
        let rawPhrase = separator.map { String(text[..<$0]) } ?? text
        let compatible = rawPhrase.precomposedStringWithCompatibilityMapping
        let visible = String(String.UnicodeScalarView(compatible.unicodeScalars.filter {
            !$0.properties.isDefaultIgnorableCodePoint && $0.properties.generalCategory != .format
        }))
        phrase = SmartEntryCurrencyText.normalized(visible)
        let rawNote = separator.map {
            String(text[text.index(after: $0)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        note = rawNote.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One number is evidence; several numbers need an explicit total or review.
/// Never sum prices, infer a sign, or salvage part of a malformed decimal.
struct SmartEntryAmountReading {
    let amount: Decimal?
    let consumedText: String?
    let needsReview: Bool

    private static let number = #"(?<![0-9.,])[0-9]+(?:[.,][0-9]+)*(?![0-9.,])"#
    private static let totalPrefix = #"(?i)(?<![a-z])(?:total|合计|合計|总计|總計)\s*[:：]?\s*(?:(?:[a-z]{3}|US\$|S\$|HK\$|A\$|RM|RMB|[$€£₹¥￥])\s*)?$"#

    private static let numberRegex = try? NSRegularExpression(pattern: number)
    private static let totalRegex = try? NSRegularExpression(pattern: totalPrefix)

    init(text: String, locale: Locale) {
        let matches = Self.matches(in: text)
        let totals = matches.filter { match in
            Self.totalRange(in: text[..<match.range.lowerBound]) != nil
        }
        let selected = totals.count == 1 ? totals.first
            : (matches.count == 1 ? matches.first : nil)
        let value = selected.flatMap { match -> Decimal? in
            // Decimal cannot retain arbitrary precision. Reject long tokens
            // before conversion rather than rounding them into valid money.
            guard match.text.filter(\.isNumber).count <= 38 else { return nil }
            return TextScanner.decimal(from: match.text, locale: locale)
        }
        amount = value.flatMap { $0 > .zero ? $0 : nil }
        if let selected, amount != nil {
            let currencyRange = Self.includingCurrency(around: selected.range, in: text)
            let prefix = text[..<currencyRange.lowerBound]
            let label = Self.totalRange(in: prefix)
            consumedText = String(text[(label?.lowerBound ?? currencyRange.lowerBound)..<currencyRange.upperBound])
        } else {
            consumedText = nil
        }
        needsReview = !matches.isEmpty && amount == nil
    }

    private struct Match {
        let text: String
        let range: Range<String.Index>
    }

    private static func includingCurrency(around range: Range<String.Index>, in text: String) -> Range<String.Index> {
        let marker = #"(?:[a-z]{3}|US\$|S\$|HK\$|A\$|RM|RMB|[$€£₹¥￥])"#
        let before = text[..<range.lowerBound]
        if let prefix = before.range(of: "(?i)(?<![a-z])" + marker + #"\s*$"#, options: .regularExpression) {
            let candidate = String(text[prefix.lowerBound..<range.upperBound])
            let evidence = ReceiptTextParser.currencyEvidence(in: [candidate])
            if !evidence.codes.isEmpty || evidence.hasAmbiguousSymbol {
                return prefix.lowerBound..<range.upperBound
            }
        }
        let after = text[range.upperBound...]
        if let suffix = after.range(of: #"(?i)^\s*"# + marker + "(?![a-z])", options: .regularExpression) {
            let candidate = String(text[range.lowerBound..<suffix.upperBound])
            let evidence = ReceiptTextParser.currencyEvidence(in: [candidate])
            if !evidence.codes.isEmpty || evidence.hasAmbiguousSymbol {
                return range.lowerBound..<suffix.upperBound
            }
        }
        return range
    }

    private static func matches(in text: String) -> [Match] {
        guard let regex = numberRegex else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            // Keep number-bearing merchants intact (7-Eleven, H2O). Signs
            // stay in the candidate so -12 is rejected instead of becoming +12.
            let before = text[..<range.lowerBound]
            let after = text[range.upperBound...]
            if after.first == ":" { return nil }
            if before.last == ":", totalRange(in: before) == nil { return nil }
            if after.first == "-" || after.first == "/" || before.last == "/" { return nil }
            let adjacentLatin = before.last.map(Self.isLatinLetter) == true
                || after.first.map(Self.isLatinLetter) == true
            if adjacentLatin, totalRange(in: before) == nil,
               ReceiptTextParser.currencyEvidence(in: [String(before.suffix(4)) + String(text[range]) + String(after.prefix(4))]).codes.isEmpty {
                return nil
            }
            let start = before.last == "-" || before.last == "+"
                ? text.index(before: range.lowerBound) : range.lowerBound
            return Match(text: String(text[start..<range.upperBound]), range: start..<range.upperBound)
        }
    }

    private static func totalRange(in text: Substring) -> Range<String.Index>? {
        guard let match = totalRegex?.firstMatch(in: String(text), range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(match.range, in: text)
    }

    private static func isLatinLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
    }
}
