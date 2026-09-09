import Foundation

/// Calendar arithmetic preserves civil days through DST. Multiple date phrases
/// are unresolved; a number in "3 days ago" can never become money.
struct SmartEntryRelativeDate {
    let date: Date?
    let remainder: String
    let found: Bool
    let isAmbiguous: Bool

    private static let pattern = try? NSRegularExpression(pattern:
        #"(?i)(?<![\p{L}\p{N}])(?:day before yesterday|yesterday|tomorrow|today|[0-9]+\s+days?\s+ago|(?:last|next|this)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))(?![\p{L}\p{N}])|(?:[0-9]+天前|前天|昨天|昨日|今天|今日|明天|明日|[上下本这這](?:周|週|星期)[一二三四五六日天])"#)

    init(text: String, now: Date, calendar: Calendar) {
        let matches = Self.pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        found = !matches.isEmpty
        var output = text
        for match in matches.reversed() {
            if let range = Range(match.range, in: output) { output.replaceSubrange(range, with: " ") }
        }
        remainder = output
        guard matches.count == 1, let match = matches.first, let range = Range(match.range, in: text) else {
            date = nil
            isAmbiguous = matches.count > 1
            return
        }
        date = Self.resolve(String(text[range]).lowercased(), now: now, calendar: calendar)
        isAmbiguous = date == nil
    }

    private static func resolve(_ token: String, now: Date, calendar: Calendar) -> Date? {
        let offsets = ["day before yesterday": -2, "前天": -2, "yesterday": -1, "昨天": -1, "昨日": -1,
                       "today": 0, "今天": 0, "今日": 0, "tomorrow": 1, "明天": 1, "明日": 1]
        if let offset = offsets[token] { return calendar.date(byAdding: .day, value: offset, to: now) }
        if let first = token.first, first.isNumber {
            guard let days = Int(token.prefix(while: \.isNumber)), days <= 36_500 else { return nil }
            return calendar.date(byAdding: .day, value: -days, to: now)
        }
        let weekdays = ["monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6,
                        "saturday": 7, "sunday": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        guard let weekday = weekdays.first(where: { token.hasSuffix($0.key) })?.value else { return nil }
        let current = calendar.component(.weekday, from: now)
        let offset: Int
        if token.hasPrefix("last ") { offset = -((current - weekday + 6) % 7 + 1) }
        else if token.hasPrefix("next ") { offset = (weekday - current + 6) % 7 + 1 }
        else {
            // Chinese 上周/下周 and English "this" use a Monday-start civil week.
            let weeks = token.hasPrefix("上") ? -1 : (token.hasPrefix("下") ? 1 : 0)
            offset = weeks * 7 + (weekday + 5) % 7 - (current + 5) % 7
        }
        return calendar.date(byAdding: .day, value: offset, to: now)
    }
}
