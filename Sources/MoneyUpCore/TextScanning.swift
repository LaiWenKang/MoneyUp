import Foundation

/// One amount found in free text, with the exact substring it came from so a
/// caller can remove it before interpreting the rest.
public struct AmountMatch: Equatable, Sendable {
    public let value: Decimal
    public let text: String

    public init(value: Decimal, text: String) {
        self.value = value
        self.text = text
    }
}

/// Deterministic scanners shared by the receipt and natural-language parsers.
///
/// Everything here is plain pattern matching over text that never leaves the
/// device. No model, no network, and the same input always produces the same
/// output, which is what makes a wrong reading debuggable.
public enum TextScanner {
    /// Candidate number grammar. Locale-specific interpretation happens only
    /// after the complete token is isolated, so `12,50` is never silently
    /// reinterpreted as `1,250` or truncated to `12`.
    private static let amountPattern =
        "(?<![0-9.,:])[0-9]+(?:[.,][0-9]+)*(?![0-9.,:])"

    /// Dates in the formats that actually turn up on receipts and in typed
    /// notes, including the Chinese form the app already ships a UI for.
    private static let datePatterns = [
        "([0-9]{4})[-/.]([0-9]{1,2})[-/.]([0-9]{1,2})",
        "([0-9]{4})年([0-9]{1,2})月([0-9]{1,2})日",
        "([0-9]{1,2})[-/.]([0-9]{1,2})[-/.]([0-9]{4})"
    ]

    public static func amounts(
        in text: String,
        locale: Locale = .current
    ) -> [AmountMatch] {
        guard let regex = try? NSRegularExpression(pattern: amountPattern) else {
            return []
        }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, range: full).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let matched = String(text[range])
            guard let value = decimal(from: matched, locale: locale) else { return nil }
            return AmountMatch(value: value, text: matched)
        }
    }

    /// A calendar date written in the text, or `nil` when none is present.
    ///
    /// `dd/mm` and `mm/dd` are genuinely ambiguous. When the first component
    /// is above twelve the reading is forced; otherwise the caller's locale
    /// decides, which is the only honest tie-break available offline.
    public static func date(
        in text: String,
        calendar: Calendar,
        prefersDayFirst: Bool
    ) -> DateComponents? {
        for pattern in datePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: full),
                  match.numberOfRanges == 4 else { continue }

            let parts = (1...3).compactMap { index -> Int? in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return Int(text[range])
            }
            guard parts.count == 3 else { continue }

            var components = DateComponents()
            if parts[0] > 31 {
                components.year = parts[0]
                components.month = parts[1]
                components.day = parts[2]
            } else if parts[0] > 12 {
                components.day = parts[0]
                components.month = parts[1]
                components.year = parts[2]
            } else if parts[1] > 12 {
                components.month = parts[0]
                components.day = parts[1]
                components.year = parts[2]
            } else {
                components.day = prefersDayFirst ? parts[0] : parts[1]
                components.month = prefersDayFirst ? parts[1] : parts[0]
                components.year = parts[2]
            }

            guard let month = components.month, (1...12).contains(month),
                  let day = components.day, (1...31).contains(day),
                  let year = components.year, (1900...2200).contains(year) else {
                continue
            }
            components.calendar = calendar
            return components
        }
        return nil
    }

    /// Case- and diacritic-insensitive comparison key, so "Café Nero" typed
    /// without the accent still matches a stored payee.
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decimal(from text: String, locale: Locale) -> Decimal? {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator
        let parts = text.components(separatedBy: decimalSeparator)
        guard parts.count <= 2 else { return nil }

        var integer = parts[0]
        if let groupingSeparator,
           !groupingSeparator.isEmpty,
           integer.contains(groupingSeparator) {
            let groups = integer.components(separatedBy: groupingSeparator)
            guard let first = groups.first,
                  (1...3).contains(first.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else {
                return nil
            }
            integer = groups.joined()
        }

        // A non-locale separator is accepted only when it was a valid grouping
        // separator above. This makes the ambiguous `1.234` follow the locale.
        guard !integer.contains("."), !integer.contains(",") else { return nil }
        guard !integer.isEmpty, integer.allSatisfy(\.isNumber) else { return nil }

        var normalized = integer
        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }
            normalized += "." + fraction
        }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }
}
