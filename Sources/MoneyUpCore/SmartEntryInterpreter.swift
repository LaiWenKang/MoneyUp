import Foundation

public enum SmartEntryShape: String, Codable, Sendable {
    case single, transfer, split, multiple
}

public enum SmartEntryIssue: String, Codable, Sendable {
    case amount, currency, date, account, category, kind, destination, receivedAmount, split, multiple, inputLimit
}

public struct SmartEntrySplit: Equatable, Sendable {
    public let categoryID: UUID
    public let amount: Decimal
}

public struct SmartEntryInterpretation: Equatable, Sendable {
    public var parsed: ParsedNaturalLanguageEntry
    public var shape: SmartEntryShape = .single
    public var sourceAccountID: UUID?
    public var destinationAccountID: UUID?
    public var destinationAmount: Decimal?
    public var destinationCurrencyEvidence = ReceiptCurrencyEvidence()
    public var splits: [SmartEntrySplit] = []
    public var issues: [SmartEntryIssue] = []
}

/// Explicit structure only: directed transfers and labelled splits. Several
/// independent transaction lines are never collapsed into one ledger entry.
public enum SmartEntryInterpreter {
    public static let maximumInputBytes = 16_384
    public static let maximumSplitLines = 32
    private static let totalPattern = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}])total(?![\p{L}])|合计|合計|总计|總計"#)
    private static let receivedPattern = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}])received(?![\p{L}])|到账|到帳|实收|實收"#)
    private static let fromPattern = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}])from(?![\p{L}])|从|從"#)
    private static let toPattern = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}])to(?![\p{L}])|→|到|至"#)
    private static let splitPattern = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}])split(?![\p{L}])|拆分|分摊|分攤|分账|分賬"#)
    private static let transferPattern = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}])transfer(?![\p{L}])|转账|轉帳|转入|轉入|转出|轉出"#)
    private static let unresolvedDatePattern = try? NSRegularExpression(pattern:
        #"(?i)(?<![\p{L}])(?:last|next)\s+week(?![\p{L}])|[上下](?:周|週|星期)|[0-9]{1,2}月[0-9]{1,2}日"#)

    public static func interpret(
        _ text: String, accounts: [LedgerAccount], now: Date = Date(),
        calendar: Calendar = .current, prefersDayFirst: Bool = true, locale: Locale = .current,
        expectsTransfer: Bool = false
    ) -> SmartEntryInterpretation {
        guard text.utf8.count <= maximumInputBytes, !Task.isCancelled else {
            return SmartEntryInterpretation(parsed: ParsedNaturalLanguageEntry(
                draft: TransactionDraft(source: .naturalLanguage), context: nil), issues: [.inputLimit])
        }
        let parts = SmartEntryTextParts(text)
        let parsed = NaturalLanguageEntryParser.parse(text, accounts: accounts, now: now,
            calendar: calendar, prefersDayFirst: prefersDayFirst, locale: locale)
        var result = SmartEntryInterpretation(parsed: parsed)
        let parse: (String) -> ParsedNaturalLanguageEntry = {
            NaturalLanguageEntryParser.parse($0, accounts: accounts, now: now,
                calendar: calendar, prefersDayFirst: prefersDayFirst, locale: locale)
        }
        if expectsTransfer || contains(transferPattern, in: parts.phrase) {
            result = transfer(parts.phrase, base: parsed, accounts: accounts, parse: parse)
        } else if let marker = range(splitPattern, in: parts.phrase) {
            var body = parts.phrase
            body.replaceSubrange(marker, with: " ")
            result = split(body, base: parsed, accounts: accounts, locale: locale, parse: parse)
        } else {
            let lines = parts.phrase.components(separatedBy: .newlines).filter {
                !TextScanner.amounts(in: $0, locale: locale).isEmpty
            }
            if lines.count > 1 {
                result.shape = .multiple
                result.issues.append(.multiple)
            }
        }
        if result.parsed.needsDateReview { result.issues.append(.date) }
        if result.parsed.draft.occurredAt == nil, contains(unresolvedDatePattern, in: parts.phrase) {
            result.issues.append(.date)
        }
        if result.shape == .single {
            if parsed.needsAccountReview { result.issues.append(.account) }
            if parsed.needsCategoryReview { result.issues.append(.category) }
            if parsed.needsAmountReview { result.issues.append(.amount) }
        }
        return result
    }

    private static func transfer(
        _ phrase: String, base: ParsedNaturalLanguageEntry, accounts: [LedgerAccount],
        parse: (String) -> ParsedNaturalLanguageEntry
    ) -> SmartEntryInterpretation {
        var result = SmartEntryInterpretation(parsed: base, shape: .transfer)
        let names = SmartEntryNames(text: phrase, accounts: accounts.filter { $0.kind == .asset || $0.kind == .liability })
        let route = transferRoute(names, phrase: phrase)
        result.sourceAccountID = route.source?.id
        result.destinationAccountID = route.destination?.id
        if route.source == nil || route.source?.accountType == .restrictedAllowance { result.issues.append(.account) }
        if route.destination == nil { result.issues.append(.destination) }
        if let marker = range(receivedPattern, in: phrase) {
            let sourceReading = parse(String(phrase[..<marker.lowerBound]))
            let received = parse(String(phrase[marker.upperBound...]))
            var draft = sourceReading.draft
            // Date and description describe the transfer as a whole, even
            // when written after the received amount. Only money is leg-local.
            draft.occurredAt = base.draft.occurredAt
            result.parsed = ParsedNaturalLanguageEntry(draft: draft, context: nil, note: base.note,
                currencyEvidence: sourceReading.currencyEvidence, needsAmountReview: sourceReading.needsAmountReview,
                needsDateReview: base.needsDateReview)
            result.destinationAmount = received.draft.amount
            result.destinationCurrencyEvidence = received.currencyEvidence
            if received.draft.amount == nil { result.issues.append(.receivedAmount) }
        } else if let source = route.source?.currency, let destination = route.destination?.currency, source != destination {
            result.issues.append(.receivedAmount)
        }
        if result.parsed.draft.amount == nil { result.issues.append(.amount) }
        return result
    }

    private static func transferRoute(_ names: SmartEntryNames, phrase: String) -> (source: LedgerAccount?, destination: LedgerAccount?) {
        if names.matches.count == 1, let match = names.matches.first {
            let prefix = String(phrase[..<match.range.lowerBound])
            let to = contains(toPattern, in: prefix), from = contains(fromPattern, in: prefix)
            guard to != from else { return (nil, nil) }
            return to ? (nil, match.account) : (match.account, nil)
        }
        guard names.matches.count == 2, Set(names.matches.map { $0.account.id }).count == 2,
              let first = names.matches.first, let last = names.matches.last,
              first.range.upperBound <= last.range.lowerBound else { return (nil, nil) }
        let between = String(phrase[first.range.upperBound..<last.range.lowerBound])
        let forwards = contains(toPattern, in: between), backwards = contains(fromPattern, in: between)
        guard forwards != backwards else { return (nil, nil) }
        return forwards ? (first.account, last.account) : (last.account, first.account)
    }

    private static func split(
        _ phrase: String, base: ParsedNaturalLanguageEntry, accounts: [LedgerAccount], locale: Locale,
        parse: (String) -> ParsedNaturalLanguageEntry
    ) -> SmartEntryInterpretation {
        var result = SmartEntryInterpretation(parsed: base, shape: .split)
        let names = SmartEntryNames(text: phrase, accounts: accounts.filter { $0.kind == .asset || $0.kind == .liability })
        if names.isAmbiguous { result.issues.append(.account) }
        var body = names.removingNames(from: phrase)
        let declaredTotal = contains(totalPattern, in: body)
            ? SmartEntryAmountReading(text: body, locale: locale) : nil
        if let declaredTotal {
            guard declaredTotal.amount != nil, let fragment = declaredTotal.consumedText,
                  let range = body.range(of: fragment) else { result.issues.append(.split); return result }
            body.replaceSubrange(range, with: " ")
        }
        let lines = body.components(separatedBy: CharacterSet(charactersIn: "+\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (2...maximumSplitLines).contains(lines.count) else { result.issues.append(.split); return result }
        var sum = Decimal.zero
        for line in lines {
            let names = SmartEntryNames(text: line, accounts: accounts.filter {
                $0.kind == (base.draft.kind == .income ? .income : .expense)
            }, allowJoinedAmount: true)
            let item = parse(names.removingNames(from: line))
            guard let category = names.uniqueID, !names.isAmbiguous,
                  let amount = item.draft.amount, !item.needsDateReview,
                  let next = try? CheckedDecimal.adding(sum, amount) else {
                result.issues.append(.split)
                return result
            }
            sum = next
            result.splits.append(SmartEntrySplit(categoryID: category, amount: amount))
        }
        if let total = declaredTotal?.amount, total != sum { result.issues.append(.split); return result }
        var draft = base.draft
        draft.amount = sum
        draft.accountID = names.uniqueID
        draft.categoryID = nil
        draft.payee = nil
        result.parsed = ParsedNaturalLanguageEntry(draft: draft, context: nil, note: base.note,
            currencyEvidence: base.currencyEvidence, needsDateReview: base.needsDateReview)
        return result
    }

    private static func contains(_ pattern: NSRegularExpression?, in text: String) -> Bool {
        range(pattern, in: text) != nil
    }

    private static func range(_ pattern: NSRegularExpression?, in text: String) -> Range<String.Index>? {
        guard let match = pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(match.range, in: text)
    }
}
