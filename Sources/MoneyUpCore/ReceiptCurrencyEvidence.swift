import Foundation

/// Currency evidence belongs to the screenshot, not to the selected account.
/// Multiple explicit codes stay ambiguous; the parser never chooses an FX rate.
public struct ReceiptCurrencyEvidence: Equatable, Sendable {
    public let codes: [CurrencyCode]
    public let hasAmbiguousSymbol: Bool

    public init(codes: [CurrencyCode] = [], hasAmbiguousSymbol: Bool = false) {
        self.codes = Array(Set(codes)).sorted()
        self.hasAmbiguousSymbol = hasAmbiguousSymbol
    }

    public var identifiedCurrency: CurrencyCode? { codes.count == 1 ? codes.first : nil }

    public func permitsAutomaticFill(in accountCurrency: CurrencyCode?) -> Bool {
        guard permitsExplicitUse(in: accountCurrency) else { return false }
        return !hasAmbiguousSymbol || identifiedCurrency != nil
    }

    public func permitsExplicitUse(in accountCurrency: CurrencyCode?) -> Bool {
        guard let accountCurrency else { return false }
        return codes.isEmpty || (codes.count == 1 && codes.first == accountCurrency)
    }
}

extension ReceiptTextParser {
    static func currencyEvidence(in lines: [String]) -> ReceiptCurrencyEvidence {
        var codes = Set<CurrencyCode>()
        var ambiguous = false
        for line in lines {
            var text = line.uppercased()
            for (regex, currency) in receiptCurrencyAliasMatchers {
                let range = NSRange(text.startIndex..., in: text)
                guard regex.firstMatch(in: text, range: range) != nil else { continue }
                codes.insert(currency)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            }
            ambiguous = ambiguous || text.contains("$") || text.contains("¥") || text.contains("￥")
            guard let regex = receiptCurrencyCodePattern else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let code = String(text[range])
                // "ALL ITEMS" must not become Albanian lek. A code must be
                // next to an amount or explicitly named in a currency row.
                let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let after = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let adjacentNumber = after.first?.isNumber == true || before.last?.isNumber == true
                let currencyRow = (before.isEmpty || ["CURRENCY:", "CURRENCY", "币种：", "币种"].contains(before)) && after.isEmpty
                if adjacentNumber || currencyRow, let currency = try? CurrencyCode(code) { codes.insert(currency) }
            }
        }
        return ReceiptCurrencyEvidence(codes: Array(codes), hasAmbiguousSymbol: ambiguous)
    }

    private static let receiptCurrencyAliases = [
        ("US$", "USD"), ("S$", "SGD"), ("HK$", "HKD"), ("A$", "AUD"),
        ("RM", "MYR"), ("RMB", "CNY"), ("€", "EUR"), ("£", "GBP"), ("₹", "INR")
    ]

    private static let receiptCurrencyAliasMatchers: [(NSRegularExpression, CurrencyCode)] =
        receiptCurrencyAliases.compactMap { marker, code in
            let pattern = "(?<![A-Z])" + NSRegularExpression.escapedPattern(for: marker)
                + (marker.last?.isLetter == true ? "(?![A-Z])" : "")
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let currency = try? CurrencyCode(code) else { return nil }
            return (regex, currency)
        }

    private static let receiptCurrencyCodePattern: NSRegularExpression? = {
        let codes = Set(Locale.commonISOCurrencyCodes + ["BTC", "ETH"])
            .sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?<![A-Z])(" + codes + ")(?![A-Z])")
    }()
}
