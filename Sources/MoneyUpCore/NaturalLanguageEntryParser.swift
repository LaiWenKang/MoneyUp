import Foundation

/// Reads a typed phrase such as "lunch 12.50 cash yesterday" into a draft.
///
/// Matching runs against the user's own account and category names, so the
/// vocabulary is whatever they already created. Nothing is inferred from a
/// model and nothing leaves the device.
public enum NaturalLanguageEntryParser {
    private static let incomeKeywords = [
        "salary", "wage", "wages", "income", "bonus", "payout", "received",
        "工资", "薪水", "收入", "奖金", "獎金", "收到"
    ]
    private static let refundKeywords = [
        "refund", "refunded", "returned", "reimbursed", "退款", "退货", "退貨",
        "报销", "報銷"
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
        prefersDayFirst: Bool = true,
        locale: Locale = .current
    ) -> TransactionDraft {
        var remainder = text
        let haystack = TextScanner.normalized(text).lowercased()
        let kind: DraftKind
        if refundKeywords.contains(where: { containsToken($0, in: haystack) }) {
            kind = .refund
        } else if incomeKeywords.contains(where: { containsToken($0, in: haystack) }) {
            kind = .income
        } else {
            kind = .expense
        }

        let dateResult = consumeDate(
            from: &remainder,
            now: now,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst
        )
        // When a phrase contains an impossible explicit civil date, do not
        // reinterpret one of its date components as money. Leave amount empty
        // so the normal editable review path asks the user to correct it.
        let amount = dateResult.invalidExplicitDate
            ? nil : consumeAmount(from: &remainder, locale: locale)
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
            occurredAt: dateResult.date,
            payee: payee(from: remainder),
            accountID: account,
            categoryID: category,
            source: .naturalLanguage
        )
    }

    private static func consumeAmount(
        from text: inout String,
        locale: Locale
    ) -> Decimal? {
        guard let match = TextScanner.amounts(in: text, locale: locale).first else { return nil }
        remove(match.text, from: &text)
        return match.value
    }

    private static func consumeDate(
        from text: inout String,
        now: Date,
        calendar: Calendar,
        prefersDayFirst: Bool
    ) -> (date: Date?, invalidExplicitDate: Bool) {
        let explicitDateShapeCount = TextScanner.explicitDateShapeCount(in: text)
        guard explicitDateShapeCount <= 1 else {
            // Multiple explicit dates are ambiguous. Do not choose one by
            // pattern priority or let any remaining date become the amount.
            return (nil, true)
        }
        if let match = TextScanner.dateMatch(
            in: text,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst
        ) {
            let components = match.components
            guard let parsed = calendar.date(from: components) else {
                return (nil, true)
            }
            let resolved = calendar.dateComponents(
                [.year, .month, .day],
                from: parsed
            )
            guard resolved.year == components.year,
                  resolved.month == components.month,
                  resolved.day == components.day else {
                return (nil, true)
            }
            remove(match.text, from: &text)
            return (
                atSameTimeOfDay(as: now, on: parsed, calendar: calendar),
                false
            )
        }
        if explicitDateShapeCount > 0 {
            return (nil, true)
        }

        // Longest tokens first so "day before yesterday" beats "yesterday".
        for entry in relativeDayOffsets where consumeToken(entry.token, from: &text) {
            return (
                calendar.date(byAdding: .day, value: entry.offset, to: now),
                false
            )
        }
        for entry in weekdayTokens where consumeToken(entry.token, from: &text) {
            return (
                mostRecent(
                    weekday: entry.weekday,
                    onOrBefore: now,
                    calendar: calendar
                ),
                false
            )
        }
        return (nil, false)
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
                return !name.isEmpty && containsName(name, in: haystack)
            }
            .sorted { $0.name.count > $1.name.count }

        guard let best = matches.first else { return nil }
        remove(best.name, from: &text)
        return best.id
    }

    private static func containsName(_ name: String, in haystack: String) -> Bool {
        let containsCJK = name.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
        if containsCJK { return haystack.contains(name) }

        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        ) else { return false }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    /// Latin tokens must be complete words. `Character.isLetter` and
    /// `isNumber` make the boundary check Unicode-aware, so an ASCII keyword
    /// cannot match inside an accented or non-Latin payee. Chinese tokens keep
    /// their existing substring behavior because users commonly type them
    /// without spaces, for example "昨天午餐".
    private static func containsToken(_ token: String, in text: String) -> Bool {
        firstTokenRange(of: token, in: text) != nil
    }

    @discardableResult
    private static func consumeToken(_ token: String, from text: inout String) -> Bool {
        guard let range = firstTokenRange(of: token, in: text) else { return false }
        text.replaceSubrange(range, with: " ")
        return true
    }

    private static func firstTokenRange(
        of token: String,
        in text: String
    ) -> Range<String.Index>? {
        guard !token.isEmpty else { return nil }

        let containsCJK = token.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if containsCJK {
            return text.range(of: token, options: options)
        }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                  of: token,
                  options: options,
                  range: searchStart..<text.endIndex
              ) {
            let touchesLetterOrNumberBefore = range.lowerBound > text.startIndex
                && isLetterOrNumber(text[text.index(before: range.lowerBound)])
            let touchesLetterOrNumberAfter = range.upperBound < text.endIndex
                && isLetterOrNumber(text[range.upperBound])
            if !touchesLetterOrNumberBefore && !touchesLetterOrNumberAfter {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func isLetterOrNumber(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func remove(_ fragment: String, from text: inout String) {
        guard let range = text.range(
            of: fragment,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return }
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
