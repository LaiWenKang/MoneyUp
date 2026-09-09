import Foundation

enum SmartEntryCurrencyText {
    private static let aliases = ["新加坡元": "SGD", "新币": "SGD", "新元": "SGD",
        "人民币": "CNY", "人民幣": "CNY", "美元": "USD", "美金": "USD",
        "港币": "HKD", "港幣": "HKD", "马币": "MYR", "馬幣": "MYR", "令吉": "MYR",
        "欧元": "EUR", "歐元": "EUR", "英镑": "GBP", "英鎊": "GBP", "日元": "JPY",
        "us dollars": "USD", "us dollar": "USD", "singapore dollars": "SGD", "singapore dollar": "SGD",
        "chinese yuan": "CNY", "hong kong dollars": "HKD", "ringgit": "MYR", "euros": "EUR",
        "euro": "EUR", "pounds sterling": "GBP", "yen": "JPY", "dollars": "$", "dollar": "$"]
    private static let marker = aliases.keys.sorted { $0.count > $1.count }
        .map { key in
            let escaped = NSRegularExpression.escapedPattern(for: key)
            return key.first?.isASCII == true ? "(?<![a-z])" + escaped + "(?![a-z])" : escaped
        }.joined(separator: "|")
    private static let pattern = try? NSRegularExpression(pattern:
        "(?i)(" + marker + #")\s*(?=[0-9])|(?<=[0-9])\s*("# + marker + ")")

    static func normalized(_ text: String) -> String {
        guard let pattern else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: .whitespaces).lowercased()
            if let code = aliases[value] { result.replaceSubrange(range, with: " " + code + " ") }
        }
        return result
    }
}
