import Foundation

/// Reads a typed phrase such as "lunch 12.50 cash yesterday" into a draft.
///
/// Matching runs against the user's own account and category names, so the
/// vocabulary is whatever they already created. Nothing is inferred from a
/// model and nothing leaves the device.
public enum NaturalLanguageEntryParser {
    private static let incomeKeywords = [
        "salary", "wage", "wages", "income", "bonus", "payout", "received",
        "refunded", "工资", "薪水", "收入", "奖金", "獎金", "收到", "报销", "報銷"
    ]

    private static let relativeDayOffsets: [(token: String, offset: Int)] = [
        ("day before yesterday", -2), ("前天", -2),
        ("yesterday", -1), ("昨天", -1), ("昨日", -1),
        ("tomorrow", 1), ("明天", 1), ("明日", 1),
        ("today", 0), ("今天", 0), ("今日", 0)
    ]

    /// Gregorian weekday numbers, where Sunday is 1.
    private static let weekdayTokens: [(token: String, weekday: Int)] = [
        ("sunday", 1), ("周日", 1), ("週日", 1), ("星期日", 1), ("星期天", 1),
        ("monday", 2), ("周一", 2), ("週一", 2), ("星期一", 2),
        ("tuesday", 3), ("周二", 3), ("週二", 3), ("星期二", 3),
        ("wednesday", 4), ("周三", 4), ("週三", 4), ("星期三", 4),
        ("thursday", 5), ("周四", 5), ("週四", 5), ("星期四", 5),
        ("friday", 6), ("周五", 6), ("週五", 6), ("星期五", 6),
        ("saturday", 7), ("周六", 7), ("週六", 7), ("星期六", 7)
    ]

    private static let fillerWords: Set<String> = [
        "for", "at", "on", "in", "of", "with", "from", "to", "a", "an", "the",
        "spent", "paid", "pay", "bought", "buy", "got", "and", "my", "last",
        "this", "was", "is", "cost", "costs"
    ]

    private static var fillerCharacters: CharacterSet {
        CharacterSet(charactersIn: "买買花了在用给給付的，。、,.:：-–—@#*")
    }

    public static func draft(
        from text: String,
        accounts: [LedgerAccount],
        now: Date = Date(),
        calendar: Calendar = .current,
        prefersDayFirst: Bool = true
    ) -> TransactionDraft {
        var remainder = text
        let haystack = TextScanner.normalized(text).lowercased()
        let kind: DraftKind = incomeKeywords.contains(where: { haystack.contains($0) })
            ? .income
            : .expense

        let occurredAt = consumeDate(
            from: &remainder,
            now: now,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst
        )
        let amount = consumeAmount(from: &remainder)
        let account = consumeName(
            from: &remainder,
            in: accounts.filter { ($0.kind == .asset || $0.kind == .liability) && !$0.isArchived }
        )
        let categoryKind: LedgerAccountKind = kind == .income ? .income : .expense
        let category = consumeName(
            from: &remainder,
            in: accounts.filter { $0.kind == categoryKind && !$0.isArchived }
        )

        return TransactionDraft(
            kind: kind,
            amount: amount,
            occurredAt: occurredAt,
            payee: payee(from: remainder),
            accountID: account,
            categoryID: category,
            source: .naturalLanguage
        )
    }

    private static func consumeAmount(from text: inout String) -> Decimal? {
        guard let match = TextScanner.amounts(in: text).first else { return nil }
        remove(match.text, from: &text)
        return match.value
    }

    private static func consumeDate(
        from text: inout String,
        now: Date,
        calendar: Calendar,
        prefersDayFirst: Bool
    ) -> Date? {
        if let components = TextScanner.date(
            in: text,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst
        ), let parsed = calendar.date(from: components) {
            removeDateText(from: &text)
            return atSameTimeOfDay(as: now, on: parsed, calendar: calendar)
        }

        let haystack = text.lowercased()
        // Longest tokens first so "day before yesterday" beats "yesterday".
        for entry in relativeDayOffsets where haystack.contains(entry.token) {
            remove(entry.token, from: &text)
            return calendar.date(byAdding: .day, value: entry.offset, to: now)
        }
        for entry in weekdayTokens where haystack.contains(entry.token) {
            remove(entry.token, from: &text)
            return mostRecent(weekday: entry.weekday, onOrBefore: now, calendar: calendar)
        }
        return nil
    }

    /// The user typed a day, not an instant. Keeping the current time of day
    /// preserves ordering within that day instead of pinning to midnight.
    private static func atSameTimeOfDay(
        as reference: Date,
        on day: Date,
        calendar: Calendar
    ) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: day
        ) ?? day
    }

    private static func mostRecent(
        weekday: Int,
        onOrBefore reference: Date,
        calendar: Calendar
    ) -> Date? {
        for offset in 0...6 {
            guard let candidate = calendar.date(
                byAdding: .day,
                value: -offset,
                to: reference
            ) else { continue }
            if calendar.component(.weekday, from: candidate) == weekday {
                return candidate
            }
        }
        return nil
    }

    /// Matches the longest account or category name present in the text, so a
    /// book containing both "Cash" and "Cash back" resolves the specific one.
    private static func consumeName(
        from text: inout String,
        in accounts: [LedgerAccount]
    ) -> UUID? {
        let haystack = TextScanner.normalized(text).lowercased()
        let matches = accounts
            .filter { account in
                let name = TextScanner.normalized(account.name).lowercased()
                return !name.isEmpty && haystack.contains(name)
            }
            .sorted { $0.name.count > $1.name.count }

        guard let best = matches.first else { return nil }
        remove(best.name, from: &text)
        return best.id
    }

    private static func remove(_ fragment: String, from text: inout String) {
        guard let range = text.range(
            of: fragment,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return }
        text.replaceSubrange(range, with: " ")
    }

    private static func removeDateText(from text: inout String) {
        guard let regex = try? NSRegularExpression(
            pattern: "[0-9]{1,4}[-/.年][0-9]{1,2}[-/.月][0-9]{1,4}日?"
        ) else { return }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let range = Range(match.range, in: text) else { return }
        text.replaceSubrange(range, with: " ")
    }

    private static func payee(from remainder: String) -> String? {
        let words = remainder
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: fillerCharacters) }
            .filter { !$0.isEmpty && !fillerWords.contains($0.lowercased()) }

        let joined = words.joined(separator: " ").trimmingCharacters(in: fillerCharacters)
        guard !joined.isEmpty, joined.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return String(joined.prefix(64))
    }
}
