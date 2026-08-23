import Foundation

/// Turns the lines a receipt scan produced into a draft transaction.
///
/// The parser is deliberately conservative. Where a receipt is ambiguous it
/// leaves the field empty rather than guessing, because an unfilled field is
/// obvious to the user while a confidently wrong total is not.
public enum ReceiptTextParser {
    /// Labels that mark the amount actually payable.
    private static let totalKeywords = [
        "grand total", "amount due", "amount payable", "balance due", "total",
        "合计", "合計", "总计", "總計", "总额", "總額", "应付", "應付", "实付", "實付"
    ]

    /// Labels that sit next to a number which is *not* the payable amount.
    /// Checked first, because "subtotal" contains "total".
    private static let excludedKeywords = [
        "subtotal", "sub total", "sub-total", "小计", "小計",
        "tax", "gst", "vat", "service charge", "服务费", "服務費",
        "change", "找零", "gratuity", "discount", "折扣",
        "saving", "points", "积分", "積分", "card", "acct", "auth"
    ]

    public static func draft(
        fromLines lines: [String],
        now: Date = Date(),
        calendar: Calendar = .current,
        prefersDayFirst: Bool = true
    ) -> TransactionDraft {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return TransactionDraft(
            kind: .expense,
            amount: total(in: cleaned),
            occurredAt: date(in: cleaned, now: now, calendar: calendar, prefersDayFirst: prefersDayFirst),
            payee: merchant(in: cleaned),
            source: .receipt
        )
    }

    private static func merchant(in lines: [String]) -> String? {
        for line in lines.prefix(5) {
            let letters = line.filter { $0.isLetter }
            guard letters.count >= 3, letters.count * 2 >= line.count else { continue }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "*-=_ "))
            guard !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }

    private static func date(
        in lines: [String],
        now: Date,
        calendar: Calendar,
        prefersDayFirst: Bool
    ) -> Date? {
        guard let earliest = calendar.date(byAdding: .year, value: -3, to: now),
              let latest = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }

        for line in lines {
            guard let components = TextScanner.date(
                in: line,
                calendar: calendar,
                prefersDayFirst: prefersDayFirst
            ), let parsed = calendar.date(from: components) else { continue }
            guard parsed >= earliest, parsed <= latest else { continue }
            return parsed
        }
        return nil
    }

    private static func total(in lines: [String]) -> Decimal? {
        // Grand totals sit near the bottom, so the last labelled line wins.
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[index].lowercased()
            guard !excludedKeywords.contains(where: { line.contains($0) }) else { continue }
            guard totalKeywords.contains(where: { line.contains($0) }) else { continue }

            if let amount = preferredAmount(in: lines[index]) { return amount }
            // Some layouts put the label on one line and the figure below it.
            if index + 1 < lines.count, let amount = preferredAmount(in: lines[index + 1]) {
                return amount
            }
        }
        return fallbackTotal(in: lines)
    }

    /// Without a label, only a figure written with decimals is trustworthy —
    /// a bare integer run is as likely to be a card, phone, or invoice number.
    private static func fallbackTotal(in lines: [String]) -> Decimal? {
        let tail = lines.suffix(max(1, lines.count / 3))
        let candidates = tail
            .flatMap { TextScanner.amounts(in: $0) }
            .filter { $0.text.contains(".") }
        return candidates.map(\.value).max()
    }

    private static func preferredAmount(in line: String) -> Decimal? {
        let matches = TextScanner.amounts(in: line)
        guard !matches.isEmpty else { return nil }
        let decimals = matches.filter { $0.text.contains(".") }
        return (decimals.isEmpty ? matches : decimals).map(\.value).max()
    }
}
