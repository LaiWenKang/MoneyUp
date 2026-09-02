import Foundation

/// The deterministic parse plus a bounded, nonfinancial text fragment that an
/// optional on-device classifier may use to rank existing local choices.
/// Monetary and date spans stay only in `draft`; they never enter `context`.
public struct ParsedNaturalLanguageEntry: Equatable, Sendable {
    public let draft: TransactionDraft
    public let context: String?

    public init(draft: TransactionDraft, context: String?) {
        self.draft = draft
        self.context = context
    }
}

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
        parse(
            text,
            accounts: accounts,
            now: now,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst,
            locale: locale
        ).draft
    }

    /// Runs the same deterministic parser while keeping its financial spans
    /// separate from the optional-assistance context. The context keeps whole
    /// tokens under 128 scalars and 256 UTF-8 bytes, and removes digits,
    /// symbols, dates, exact local names, and recognized currency codes before
    /// any model boundary can see it.
    public static func parse(
        _ text: String,
        accounts: [LedgerAccount],
        now: Date = Date(),
        calendar: Calendar = .current,
        prefersDayFirst: Bool = true,
        locale: Locale = .current
    ) -> ParsedNaturalLanguageEntry {
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

        let draft = TransactionDraft(
            kind: kind,
            amount: amount,
            occurredAt: dateResult.date,
            payee: payee(from: remainder),
            accountID: account,
            categoryID: category,
            source: .naturalLanguage
        )
        let currencyCodes = Set(
            accounts.compactMap { $0.currency?.value.lowercased() }
        )
        return ParsedNaturalLanguageEntry(
            draft: draft,
            context: assistanceContext(
                from: remainder,
                currencyCodes: currencyCodes,
                localNames: accounts.map(\.name)
            )
        )
    }

    private static func assistanceContext(
        from remainder: String,
        currencyCodes: Set<String>,
        localNames: [String]
    ) -> String? {
        let comparableCurrencyCodes = Set(
            currencyCodes.map(assistanceComparisonKey)
        )
        let separators = CharacterSet.decimalDigits
            .union(.symbols)
            .union(.punctuationCharacters)
        var sanitized = ""
        for scalar in remainder.precomposedStringWithCompatibilityMapping.unicodeScalars {
            let properties = scalar.properties
            let category = properties.generalCategory
            if properties.isDefaultIgnorableCodePoint || category == .format {
                continue
            }
            if separators.contains(scalar)
                || category == .control {
                sanitized.append(" ")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        let trimSet = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
            .union(fillerCharacters)
        let words = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { word in
                guard !word.isEmpty else { return false }
                let lowered = word.lowercased()
                if fillerWords.contains(lowered) { return false }
                let comparisonKey = assistanceComparisonKey(word)
                if comparableCurrencyCodes.contains(comparisonKey) {
                    return false
                }
                let asciiLetters = word.unicodeScalars.allSatisfy {
                    (65...90).contains($0.value) || (97...122).contains($0.value)
                }
                return !(asciiLetters && word.count == 3
                    && word == word.uppercased())
            }
        let fullContext = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullContext.isEmpty,
              fullContext.contains(where: { $0.isLetter }),
              !containsLocalName(fullContext, localNames: localNames),
              let boundedContext = boundedAssistanceContext(words),
              boundedContext.contains(where: { $0.isLetter }),
              !containsLocalName(boundedContext, localNames: localNames)
        else { return nil }
        return boundedContext
    }

    private static func boundedAssistanceContext(_ words: [String]) -> String? {
        var context = ""
        var scalarCount = 0
        var utf8Count = 0
        for word in words {
            let separatorCount = context.isEmpty ? 0 : 1
            let nextScalarCount = scalarCount + separatorCount
                + word.unicodeScalars.count
            let nextUTF8Count = utf8Count + separatorCount + word.utf8.count
            guard nextScalarCount <= 128, nextUTF8Count <= 256 else { break }
            if separatorCount == 1 {
                context.append(" ")
            }
            context.append(word)
            scalarCount = nextScalarCount
            utf8Count = nextUTF8Count
        }
        return context.isEmpty ? nil : context
    }

    private static func containsLocalName(
        _ context: String,
        localNames: [String]
    ) -> Bool {
        let projectedContext = searchProjection(of: context).text
        return localNames.contains { name in
            let projectedName = searchProjection(
                of: TextScanner.normalized(name)
            ).text
            return firstProjectedTokenRange(
                of: projectedName,
                in: projectedContext
            ) != nil
        }
    }

    private static func assistanceComparisonKey(_ value: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        return value.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
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
        let matches = accounts.compactMap { account -> NameMatch? in
            let name = TextScanner.normalized(account.name)
            guard !name.isEmpty,
                  let range = firstTokenRange(of: name, in: text) else {
                return nil
            }
            return NameMatch(
                accountID: account.id,
                normalizedName: name,
                range: range,
                location: text.distance(from: text.startIndex, to: range.lowerBound)
            )
        }.sorted { first, second in
            if first.normalizedName.count != second.normalizedName.count {
                return first.normalizedName.count > second.normalizedName.count
            }
            if first.location != second.location {
                return first.location < second.location
            }
            if first.normalizedName != second.normalizedName {
                return first.normalizedName < second.normalizedName
            }
            return first.accountID.uuidString < second.accountID.uuidString
        }
        guard let best = matches.first else { return nil }
        text.replaceSubrange(best.range, with: " ")
        return best.accountID
    }

    private struct NameMatch {
        let accountID: UUID
        let normalizedName: String
        let range: Range<String.Index>
        let location: Int
    }

    /// Latin tokens must be complete Unicode words, looking through combining
    /// and default-ignorable scalars at each boundary. Chinese tokens keep
    /// their intentional substring behavior because users commonly type them
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
        let projectedToken = searchProjection(of: token).text
        let projectedText = searchProjection(of: text)
        guard let range = firstProjectedTokenRange(
            of: projectedToken,
            in: projectedText.text
        ) else { return nil }
        return originalRange(for: range, in: projectedText)
    }

    private static func firstProjectedTokenRange(
        of token: String,
        in text: String
    ) -> Range<String.Index>? {
        guard !token.isEmpty, !text.isEmpty else { return nil }
        let containsCJK = token.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive
        ]
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
            let touchesLetterOrNumberBefore = touchesLetterOrNumber(
                before: range.lowerBound,
                in: text
            )
            let touchesLetterOrNumberAfter = touchesLetterOrNumber(
                after: range.upperBound,
                in: text
            )
            if !touchesLetterOrNumberBefore && !touchesLetterOrNumberAfter {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private struct SearchProjection {
        let text: String
        let originalRanges: [Range<String.Index>]
    }

    private static func searchProjection(of source: String) -> SearchProjection {
        var text = ""
        var originalRanges: [Range<String.Index>] = []
        var index = source.startIndex
        while index < source.endIndex {
            let next = source.index(after: index)
            let compatible = String(source[index])
                .precomposedStringWithCompatibilityMapping
            for projectedScalar in compatible.unicodeScalars
            where !isDefaultIgnorableOrFormat(projectedScalar) {
                text.unicodeScalars.append(projectedScalar)
                originalRanges.append(index..<next)
            }
            index = next
        }
        return SearchProjection(
            text: text,
            originalRanges: originalRanges
        )
    }

    private static func originalRange(
        for range: Range<String.Index>,
        in projection: SearchProjection
    ) -> Range<String.Index>? {
        let scalars = projection.text.unicodeScalars
        let lowerOffset = scalars.distance(
            from: scalars.startIndex,
            to: range.lowerBound
        )
        let upperOffset = scalars.distance(
            from: scalars.startIndex,
            to: range.upperBound
        )
        guard lowerOffset >= 0,
              upperOffset > lowerOffset,
              upperOffset <= projection.originalRanges.count else {
            return nil
        }
        return projection.originalRanges[lowerOffset].lowerBound
            ..<projection.originalRanges[upperOffset - 1].upperBound
    }

    private static func touchesLetterOrNumber(
        before index: String.Index,
        in text: String
    ) -> Bool {
        var cursor = index
        while cursor > text.unicodeScalars.startIndex {
            let previous = text.unicodeScalars.index(before: cursor)
            let scalar = text.unicodeScalars[previous]
            if isIgnoredTokenBoundaryScalar(scalar) {
                cursor = previous
                continue
            }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return false
    }

    private static func touchesLetterOrNumber(
        after index: String.Index,
        in text: String
    ) -> Bool {
        var cursor = index
        while cursor < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[cursor]
            if isIgnoredTokenBoundaryScalar(scalar) {
                cursor = text.unicodeScalars.index(after: cursor)
                continue
            }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return false
    }

    private static func isIgnoredTokenBoundaryScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .format, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return properties.isDefaultIgnorableCodePoint
        }
    }

    private static func isDefaultIgnorableOrFormat(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        scalar.properties.isDefaultIgnorableCodePoint
            || scalar.properties.generalCategory == .format
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
