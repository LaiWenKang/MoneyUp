import Foundation

extension ReceiptTextParser {
    static func rankedDates(
        in lines: [String],
        now: Date,
        calendar: Calendar,
        prefersDayFirst: Bool
    ) -> [RankedDate] {
        guard let earliest = calendar.date(byAdding: .year, value: -3, to: now),
              let latest = calendar.date(byAdding: .day, value: 1, to: now) else {
            return []
        }

        var candidates: [RankedDate] = []
        for (index, line) in lines.enumerated() {
            let normalized = normalizedLine(line)
            guard !containsAny(dateExclusionLabels, in: normalized) else { continue }
            guard let value = parsedDate(
                in: line,
                calendar: calendar,
                prefersDayFirst: prefersDayFirst
            ), value >= earliest, value <= latest else { continue }

            var score = 30
            if containsAny(["transaction date", "payment date", "purchase date", "paid on",
                            "date/time", "datetime", "交易日期", "付款日期", "消费日期"],
                           in: normalized) {
                score += 70
            } else if containsAny(["date", "日期"], in: normalized) {
                score += 25
            }
            if timeComponents(in: line) != nil { score += 10 }
            score += max(0, 10 - index)
            candidates.append(RankedDate(value: value, lineIndex: index, score: score))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            return lhs.value > rhs.value
        }
    }

    static func parsedDate(
        in line: String,
        calendar: Calendar,
        prefersDayFirst: Bool
    ) -> Date? {
        var components = TextScanner.date(
            in: line,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst
        )

        if components == nil {
            components = shortNumericDate(
                in: line,
                calendar: calendar,
                prefersDayFirst: prefersDayFirst
            )
        }
        if components == nil {
            components = namedMonthDate(in: line, calendar: calendar)
        }
        guard var components else { return nil }

        if let time = timeComponents(in: line) {
            components.hour = time.hour
            components.minute = time.minute
            components.second = time.second
        }
        components.calendar = calendar
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == components.year,
              resolved.month == components.month,
              resolved.day == components.day else { return nil }
        return date
    }

    static func shortNumericDate(
        in line: String,
        calendar: Calendar,
        prefersDayFirst: Bool
    ) -> DateComponents? {
        let pattern = #"(?<![0-9])([0-9]{1,2})[-/.]([0-9]{1,2})[-/.]([0-9]{2})(?![0-9])"#
        guard let parts = captures(pattern: pattern, in: line), parts.count == 3,
              let first = Int(parts[0]), let second = Int(parts[1]),
              let shortYear = Int(parts[2]) else { return nil }

        let day: Int
        let month: Int
        if first > 12 {
            day = first
            month = second
        } else if second > 12 {
            day = second
            month = first
        } else {
            day = prefersDayFirst ? first : second
            month = prefersDayFirst ? second : first
        }
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        return DateComponents(calendar: calendar, year: 2000 + shortYear, month: month, day: day)
    }

    static func namedMonthDate(in line: String, calendar: Calendar) -> DateComponents? {
        let monthPattern = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|" +
            "jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|" +
            "nov(?:ember)?|dec(?:ember)?"
        let dayFirst = "(?i)(?<![a-z0-9])([0-9]{1,2})(?:st|nd|rd|th)?[\\s-]+" +
            "(\(monthPattern))[\\s,/-]+([0-9]{2,4})(?![0-9])"
        let monthFirst = "(?i)(?<![a-z0-9])(\(monthPattern))[\\s-]+" +
            "([0-9]{1,2})(?:st|nd|rd|th)?[\\s,/-]+([0-9]{2,4})(?![0-9])"

        if let parts = captures(pattern: dayFirst, in: line), parts.count == 3,
           let day = Int(parts[0]), let month = monthNumber(parts[1]),
           let year = normalizedYear(parts[2]) {
            return validDateComponents(day: day, month: month, year: year, calendar: calendar)
        }
        if let parts = captures(pattern: monthFirst, in: line), parts.count == 3,
           let month = monthNumber(parts[0]), let day = Int(parts[1]),
           let year = normalizedYear(parts[2]) {
            return validDateComponents(day: day, month: month, year: year, calendar: calendar)
        }
        return nil
    }

    static func validDateComponents(
        day: Int,
        month: Int,
        year: Int,
        calendar: Calendar
    ) -> DateComponents? {
        guard (1...31).contains(day), (1...12).contains(month), (1900...2200).contains(year) else {
            return nil
        }
        return DateComponents(calendar: calendar, year: year, month: month, day: day)
    }

    static func normalizedYear(_ text: String) -> Int? {
        guard let value = Int(text) else { return nil }
        return text.count == 2 ? 2000 + value : value
    }

    static func monthNumber(_ text: String) -> Int? {
        let prefix = String(text.lowercased().prefix(3))
        return [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ][prefix]
    }

    static func timeComponents(in line: String) -> DateComponents? {
        let pattern = #"(?i)(?<![0-9])([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?\s*(am|pm)?(?![a-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: full),
              let hourText = capture(match, at: 1, in: line),
              let minuteText = capture(match, at: 2, in: line),
              var hour = Int(hourText), let minute = Int(minuteText),
              (0...59).contains(minute) else { return nil }
        let second = capture(match, at: 3, in: line).flatMap(Int.init) ?? 0
        let meridiem = capture(match, at: 4, in: line)?.lowercased()

        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "pm", hour != 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        } else {
            guard (0...23).contains(hour) else { return nil }
        }
        guard (0...59).contains(second) else { return nil }
        return DateComponents(hour: hour, minute: minute, second: second)
    }

    static func dateAndTimeRanges(in line: String) -> [NSRange] {
        let patterns = [
            #"(?<![0-9])(?:19|20)[0-9]{2}[-/.年][0-9]{1,2}[-/.月][0-9]{1,2}日?(?![0-9])"#,
            #"(?<![0-9])[0-9]{1,2}[-/.][0-9]{1,2}[-/.](?:[0-9]{2}|[0-9]{4})(?![0-9])"#,
            #"(?i)(?<![0-9])[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?\s*(?:am|pm)?(?![a-z0-9])"#
        ]
        let full = NSRange(line.startIndex..<line.endIndex, in: line)
        return patterns.flatMap { pattern -> [NSRange] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: line, range: full).map(\.range)
        }
    }

    // MARK: - Category and note

    static func categoryHint(
        in lines: [String],
        merchant: String?
    ) -> ReceiptCategoryHint? {
        let text = normalizedLine(([merchant].compactMap { $0 } + lines).joined(separator: " "))
        let rules: [(ReceiptCategoryHint, [String])] = [
            (.groceries, ["fairprice", "ntuc", "cold storage", "sheng siong", "giant",
                           "jaya grocer", "village grocer", "lotus's", "lotus ", "supermarket",
                           "grocery", "groceries", "hypermarket", "杂货", "雜貨", "超市"]),
            (.transport, ["trip fare", "ride fare", "taxi", "comfortdelgro", "gojek",
                          "rapidkl", "mrt", " lrt", " bus", "parking", "car park", "toll",
                          "petrol", "diesel", "fuel", "shell", "caltex", "esso", "交通",
                          "车费", "車費", "停车", "停車"]),
            (.food, ["grabfood", "foodpanda", "restaurant", "cafe", "café", "coffee",
                     "kopitiam", "hawker", "bakery", "bistro", "kitchen", "pizza", "burger",
                     "sushi", "ramen", "noodle", "chicken rice", "meal", "dining", "餐厅",
                     "餐廳", "火锅", "火鍋", "咖啡", "茶餐", "饭店", "飯店"]),
            (.healthcare, ["clinic", "hospital", "medical", "dental", "dentist", "pharmacy",
                           "watsons", "guardian health", "polyclinic", "药房", "藥房", "诊所",
                           "診所", "医院", "醫院"]),
            (.utilities, ["sp services", "singapore power", "electricity", "water bill",
                          "utilities", "singtel", "starhub", "m1 limited", "maxis", "celcom",
                          "digi", "unifi", "time internet", "tnb", "电费", "電費", "水费",
                          "水費", "电话费", "電話費"]),
            (.entertainment, ["cinema", "cineplex", "golden village", "tgv", "gsc",
                              "netflix", "spotify", "karaoke", "movie", "theme park", "游戏",
                              "遊戲", "电影", "電影", "娱乐", "娛樂"]),
            (.housing, ["rent", "rental", "property management", "maintenance fee",
                        "conservancy", "房租", "租金", "物业", "物業"]),
            (.shopping, ["shopee", "lazada", "uniqlo", "department store", "retail",
                         "shopping", "mall", "fashion", "apparel", "electronics", "百货",
                         "百貨", "购物", "購物", "商场", "商場"])
        ]

        let ranked = rules.enumerated().compactMap { priority, rule -> (ReceiptCategoryHint, Int, Int)? in
            let hits = rule.1.filter { text.contains($0) }.count
            guard hits > 0 else { return nil }
            return (rule.0, hits, priority)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.2 < rhs.2
        }
        return ranked.first?.0
    }

    static func categoryID(
        for hint: ReceiptCategoryHint,
        in accounts: [LedgerAccount]
    ) -> UUID? {
        let aliases: [ReceiptCategoryHint: [String]] = [
            .food: ["food", "dining", "meal", "餐饮", "餐飲", "饮食", "飲食"],
            .groceries: ["grocer", "supermarket", "日用品", "杂货", "雜貨", "food"],
            .transport: ["transport", "travel", "commute", "交通", "出行"],
            .shopping: ["shopping", "retail", "购物", "購物"],
            .entertainment: ["entertainment", "leisure", "娱乐", "娛樂"],
            .utilities: ["utilities", "bills", "utility", "水电", "水電"],
            .healthcare: ["health", "medical", "healthcare", "医疗", "醫療"],
            .housing: ["housing", "rent", "home", "房租", "住房"]
        ]
        let terms = aliases[hint] ?? []
        return accounts
            .filter { $0.kind == .expense && !$0.isArchived }
            .map { account in
                let name = normalizedLine(account.name)
                let score = terms.enumerated().reduce(0) { result, entry in
                    guard name.contains(entry.element) else { return result }
                    return max(result, 100 - entry.offset)
                }
                return (account, score)
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.name != rhs.0.name { return lhs.0.name < rhs.0.name }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }
            .first?.0.id
    }

    static func noteCandidate(in lines: [String]) -> String? {
        let explicitLabels = [
            "receipt no", "receipt #", "order no", "order #", "invoice no", "invoice #",
            "transaction id", "txn id", "reference", "ref no", "订单号", "訂單號", "单号",
            "單號", "交易号", "交易號"
        ]
        if let reference = lines.first(where: { line in
            let normalized = normalizedLine(line)
            return containsAny(explicitLabels, in: normalized)
                && !containsAny(["phone", "tel", "mobile", "电话", "電話"], in: normalized)
        }) {
            return limited(reference, to: 96)
        }

        let paymentMarkers = ["visa", "mastercard", "amex", "nets", "paynow", "duitnow",
                              "touch 'n go", "tng ewallet", "alipay", "wechat pay"]
        if let payment = lines.first(where: { line in
            let normalized = normalizedLine(line)
            return containsAny(paymentMarkers, in: normalized)
                && !containsAny(["change", "tendered", "balance"], in: normalized)
        }) {
            return limited(payment, to: 96)
        }
        return nil
    }

    // MARK: - Shared helpers

    static func cleanLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedLine(_ value: String) -> String {
        TextScanner.normalized(cleanLine(value)).lowercased()
    }

    static func containsAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains(where: { haystack.contains($0) })
    }

    static func hasCurrencyMarker(in text: String) -> Bool {
        if containsAny(["s$", "us$", "$", "€", "£", "¥"], in: text) { return true }
        let codes = currencyMarkers.filter { !$0.contains("$") && !["$", "€", "£", "¥"].contains($0) }
        return codes.contains { code in
            let escaped = NSRegularExpression.escapedPattern(for: code)
            let pattern = "(?i)(?<![a-z])" + escaped + "(?=\\s*[0-9])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, range: full) != nil
        }
    }

    static func captures(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: full) else { return nil }
        return (1..<match.numberOfRanges).compactMap { capture(match, at: $0, in: text) }
    }

    static func capture(
        _ match: NSTextCheckingResult,
        at index: Int,
        in text: String
    ) -> String? {
        guard index < match.numberOfRanges,
              match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    static func limited(_ value: String, to maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unique<T: Equatable>(_ values: [T]) -> [T] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }
}
