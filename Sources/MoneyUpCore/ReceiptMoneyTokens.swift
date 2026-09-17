import Foundation

extension ReceiptTextParser {
    /// Extracts currency-shaped numbers and repairs only the two OCR confusions
    /// that are safe inside an otherwise numeric token (`O` -> `0`, `I/l` -> `1`).
    static func moneyTokens(in line: String, locale: Locale, currency: CurrencyCode? = nil) -> [MoneyToken] {
        let pattern = #"(?<![0-9.,:])[-−]?(?:[0-9OoIl]{1,3}(?:[ '’][0-9OoIl]{3})+(?:[.,][0-9OoIl]{1,8})?|[0-9OoIl]+(?:[.,][0-9OoIl]+)*)(?![0-9.,:])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        return regex.matches(in: line, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: line) else { return nil }
            let raw = String(line[swiftRange])
            guard raw.contains(where: \.isNumber) else { return nil }
            let repaired = raw
                .replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "o", with: "0")
                .replacingOccurrences(of: "I", with: "1")
                .replacingOccurrences(of: "l", with: "1")
            guard let parsed = parseMoneyToken(repaired, locale: locale, currency: currency) else { return nil }
            return MoneyToken(
                value: parsed.value,
                range: match.range,
                hasFraction: parsed.hasFraction,
                digitCount: repaired.filter(\.isNumber).count,
                requiresReview: parsed.requiresReview
            )
        }
    }

    static func parseMoneyToken(
        _ raw: String,
        locale: Locale,
        currency: CurrencyCode? = nil
    ) -> (value: Decimal, hasFraction: Bool, requiresReview: Bool)? {
        var token = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "−", with: "-")
        guard !token.hasPrefix("-") else { return nil }
        token.removeAll(where: { $0 == "+" })
        guard !token.isEmpty else { return nil }

        let dotOffsets = token.indices.filter { token[$0] == "." }
        let commaOffsets = token.indices.filter { token[$0] == "," }
        let separatorOffsets = dotOffsets + commaOffsets
        var decimalOffset: String.Index?
        var requiresReview = false

        if let rightmost = separatorOffsets.max() {
            let fractionCount = token.distance(from: token.index(after: rightmost), to: token.endIndex)
            let leadingZero = token[..<rightmost] == "0"
            let hasGrouping = raw.contains(" ") || raw.contains("'") || raw.contains("’")
            requiresReview = (currency == nil || currency?.minorUnits == 3)
                && separatorOffsets.count == 1 && fractionCount == 3
                && !leadingZero && !hasGrouping
            if fractionCount == 1 || fractionCount == 2
                || (leadingZero && separatorOffsets.count == 1)
                || (fractionCount == currency?.minorUnits
                    && ((separatorOffsets.count == 1
                        && String(token[rightmost]) == (locale.decimalSeparator ?? "."))
                        || (!dotOffsets.isEmpty && !commaOffsets.isEmpty))) {
                decimalOffset = rightmost
            } else if separatorOffsets.count == 1,
                      fractionCount != 3,
                      String(token[rightmost]) == (locale.decimalSeparator ?? ".") {
                decimalOffset = rightmost
            }
        }

        var normalized = ""
        for index in token.indices {
            let character = token[index]
            if character.isNumber {
                normalized.append(character)
            } else if let decimalOffset, index == decimalOffset {
                normalized.append(".")
            } else if character != "." && character != "," {
                return nil
            }
        }

        guard let value = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return nil }
        return (value, decimalOffset != nil, requiresReview)
    }

}
