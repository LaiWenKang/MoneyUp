import Foundation

/// A broad semantic hint inferred from receipt text. The hint deliberately has
/// no ledger identity: callers map it onto the user's own category names.
public enum ReceiptCategoryHint: String, Equatable, Hashable, Sendable {
    case food
    case groceries
    case transport
    case shopping
    case entertainment
    case utilities
    case healthcare
    case housing
}

/// The complete, reviewable output of an on-device receipt parse.
///
/// `draft` remains the compatibility path used by transaction entry. The other
/// fields let the UI make better suggestions without rescanning or retaining
/// the receipt image. Candidate arrays are already in deterministic best-first
/// order.
public struct ReceiptParseResult: Equatable, Sendable {
    public let draft: TransactionDraft
    public let amountCandidates: [Decimal]
    public let merchantCandidates: [String]
    public let dateCandidates: [Date]
    public let categoryHint: ReceiptCategoryHint?
    public let noteCandidate: String?

    public init(
        draft: TransactionDraft,
        amountCandidates: [Decimal],
        merchantCandidates: [String],
        dateCandidates: [Date],
        categoryHint: ReceiptCategoryHint?,
        noteCandidate: String?
    ) {
        self.draft = draft
        self.amountCandidates = amountCandidates
        self.merchantCandidates = merchantCandidates
        self.dateCandidates = dateCandidates
        self.categoryHint = categoryHint
        self.noteCandidate = noteCandidate
    }
}

/// Turns OCR lines from a receipt photo or payment screenshot into a draft.
///
/// Parsing is local, deterministic, and intentionally explainable. Labelled
/// payable amounts outrank everything else; subtotal, tax, change, tendered
/// cash, balances, identifiers, dates, times, percentages, and card tails are
/// explicitly demoted or rejected.
public enum ReceiptTextParser {
    struct RankedAmount {
        let value: Decimal
        let lineIndex: Int
        let rangeLocation: Int
        let score: Int
        let isLabelled: Bool
    }

    struct RankedText {
        let value: String
        let lineIndex: Int
        let score: Int
    }

    struct RankedDate {
        let value: Date
        let lineIndex: Int
        let score: Int
    }

    struct MoneyToken {
        let value: Decimal
        let range: NSRange
        let hasFraction: Bool
        let digitCount: Int
    }

    static let payableLabels: [(String, Int)] = [
        ("grand total", 190), ("amount payable", 185), ("amount due", 185),
        ("total payable", 180), ("total due", 180), ("balance due", 180),
        ("amount paid", 175), ("total paid", 175), ("you paid", 170),
        ("payment amount", 165), ("charged amount", 165),
        ("transfer amount", 165), ("net amount", 160), ("nett amount", 160),
        ("net total", 160), ("nett total", 160), ("total amount", 155),
        ("jumlah besar", 185), ("amaun perlu dibayar", 185),
        ("jumlah bayaran", 175), ("jumlah", 160), ("total", 145),
        ("合计", 180), ("合計", 180), ("总计", 180), ("總計", 180),
        ("应付", 180), ("應付", 180), ("实付", 180), ("實付", 180),
        ("支付金额", 175), ("支付金額", 175), ("付款金额", 175),
        ("付款金額", 175)
    ]

    /// These labels identify values that are commonly larger than, or close to,
    /// the payable amount but must never win merely because of their magnitude.
    static let nonPayableLabels: [(String, Int)] = [
        ("subtotal", -240), ("sub total", -240), ("sub-total", -240),
        ("subjumlah", -240), ("jumlah kecil", -240), ("小计", -240), ("小計", -240),
        ("change", -230), ("找零", -230), ("balance change", -230),
        ("baki", -230),
        ("cash tendered", -225), ("amount tendered", -225),
        ("tendered", -210), ("cash received", -210),
        ("cash", -170), ("tunai", -170),
        ("discount", -205), ("savings", -205), ("saving", -205),
        ("voucher", -190), ("rebate", -190), ("折扣", -205),
        ("service charge", -185), ("服务费", -185), ("服務費", -185),
        ("caj perkhidmatan", -185),
        ("gratuity", -185), ("tip", -175),
        ("gst", -170), ("sst", -170), ("vat", -170), (" tax", -170),
        ("cukai", -170), ("diskaun", -205),
        ("rounding", -160), ("round off", -160),
        ("points", -220), ("积分", -220), ("積分", -220),
        ("available balance", -250), ("account balance", -250),
        ("opening balance", -250), ("closing balance", -250),
        ("total items", -260), ("total item", -260), ("total qty", -260),
        ("total quantity", -260)
    ]

    static let identifierLabels = [
        "phone", "tel", "mobile", "fax", "order no", "order #", "invoice no",
        "invoice #", "receipt no", "receipt #", "transaction id", "txn id",
        "reference", "ref no", "auth", "approval", "terminal", "merchant id",
        "member", "loyalty", "table no", "queue no", "pager", "card no",
        "acct", "account no", "电话", "電話", "订单", "訂單", "单号", "單號"
    ]

    static let currencyMarkers = [
        "s$", "sgd", "rm", "myr", "usd", "us$", "aud", "eur", "gbp",
        "cny", "rmb", "hkd", "$", "€", "£", "¥"
    ]

    static let dateExclusionLabels = [
        "best before", "use by", "expiry", "expires", "expiration", "valid thru",
        "valid through", "member since", "card expiry", "manufactured",
        "有效期", "保质期", "保質期", "到期", "生产日期", "生產日期"
    ]

    static let genericMerchantLines = [
        "tax invoice", "official receipt", "sales receipt", "payment successful",
        "transaction successful", "transaction detail", "payment details", "payment complete",
        "thank you", "welcome",
        "customer copy", "merchant copy", "duplicate copy", "invoice", "receipt"
    ]

    /// Compatibility API used by the current quick-log flow.
    public static func draft(
        fromLines lines: [String],
        now: Date = Date(),
        calendar: Calendar = .current,
        prefersDayFirst: Bool = true,
        locale: Locale = .current,
        accounts: [LedgerAccount] = []
    ) -> TransactionDraft {
        analyze(
            fromLines: lines,
            now: now,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst,
            locale: locale,
            accounts: accounts
        ).draft
    }

    /// Produces all useful candidates once so receipt entry can populate amount,
    /// date, merchant, category, and note without another OCR/parser pass.
    public static func analyze(
        fromLines lines: [String],
        now: Date = Date(),
        calendar: Calendar = .current,
        prefersDayFirst: Bool = true,
        locale: Locale = .current,
        accounts: [LedgerAccount] = []
    ) -> ReceiptParseResult {
        let cleaned = lines
            .map(cleanLine)
            .filter { !$0.isEmpty }

        let amounts = rankedAmounts(in: cleaned, locale: locale)
        let merchants = rankedMerchants(in: cleaned)
        let dates = rankedDates(
            in: cleaned,
            now: now,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst
        )
        let inferredCategory = Self.categoryHint(
            in: cleaned,
            merchant: merchants.first?.value
        )
        let categoryID = inferredCategory.flatMap {
            Self.categoryID(for: $0, in: accounts)
        }

        let draft = TransactionDraft(
            kind: .expense,
            amount: amounts.first?.value,
            occurredAt: dates.first?.value,
            payee: merchants.first?.value,
            categoryID: categoryID,
            source: .receipt
        )

        return ReceiptParseResult(
            draft: draft,
            amountCandidates: credibleAmountValues(amounts),
            merchantCandidates: unique(merchants.map(\.value)),
            dateCandidates: unique(dates.map(\.value)),
            categoryHint: inferredCategory,
            noteCandidate: noteCandidate(in: cleaned)
        )
    }

    // MARK: - Amounts

    static func rankedAmounts(
        in lines: [String],
        locale: Locale
    ) -> [RankedAmount] {
        guard !lines.isEmpty else { return [] }
        var candidates: [RankedAmount] = []

        for (lineIndex, line) in lines.enumerated() {
            let normalized = normalizedLine(line)
            let labelScore = payableScore(in: normalized)
            var previousLabelScore = 0
            if lineIndex > 0 {
                let previous = normalizedLine(lines[lineIndex - 1])
                if nonPayableScore(in: previous) == 0 {
                    previousLabelScore = payableScore(in: previous)
                }
            }
            let exclusionScore = nonPayableScore(in: normalized)
            let isInclusiveTotal = isInclusivePayableLine(normalized)
            let hasCurrency = hasCurrencyMarker(in: normalized)
            let identifierContext = containsAny(identifierLabels, in: normalized)
            let protectedRanges = dateAndTimeRanges(in: line)

            for token in moneyTokens(in: line, locale: locale) {
                guard token.value > .zero else { continue }
                // A tax, discount, subtotal, tendered cash, change, points, or
                // balance line is not the transaction amount. When a receipt
                // explicitly says the payable total includes tax/service, the
                // same line is safe and is handled by the restoration below.
                guard exclusionScore == 0 || isInclusiveTotal else { continue }
                guard !protectedRanges.contains(where: { NSIntersectionRange($0, token.range).length > 0 }) else {
                    continue
                }
                guard !isPercentage(token.range, in: line) else { continue }

                var score = 0
                var isLabelled = false
                if labelScore > 0 {
                    score += labelScore
                    isLabelled = true
                } else if previousLabelScore > 0, isMostlyAmount(line) {
                    score += previousLabelScore - 10
                    isLabelled = true
                }

                score += exclusionScore
                if hasCurrency { score += 24 }
                if token.hasFraction { score += 20 }
                score += Int((Double(lineIndex) / Double(max(lines.count - 1, 1))) * 18)

                if identifierContext { score -= token.hasFraction ? 140 : 280 }
                if containsAny(["card", "visa", "mastercard", "amex", "nets"], in: normalized),
                   labelScore == 0 {
                    score -= token.hasFraction ? 35 : 220
                }
                if containsAny(["qty", "quantity", "unit price", "x @", " x "], in: normalized),
                   labelScore == 0 {
                    score -= 55
                }
                if !token.hasFraction, !hasCurrency, !isLabelled { score -= 90 }
                if token.digitCount >= 7 { score -= 320 }
                if token.value > Decimal(10_000_000) { score -= 300 }

                // Restore an exclusion only for an explicitly inclusive total,
                // such as "TOTAL (incl. GST)". A payable-looking substring in
                // TOTAL SAVINGS, TOTAL DISCOUNT, TOTAL POINTS, or a balance must
                // never cancel the exclusion for that non-payable value.
                if labelScore > 0, exclusionScore < 0, isInclusiveTotal {
                    score -= exclusionScore * 3 / 4
                }

                candidates.append(
                    RankedAmount(
                        value: token.value,
                        lineIndex: lineIndex,
                        rangeLocation: token.range.location,
                        score: score,
                        isLabelled: isLabelled
                    )
                )
            }
        }

        return candidates
            .filter { $0.score >= 20 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.isLabelled != rhs.isLabelled { return lhs.isLabelled }
                if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex > rhs.lineIndex }
                if lhs.rangeLocation != rhs.rangeLocation {
                    return lhs.rangeLocation > rhs.rangeLocation
                }
                return lhs.value > rhs.value
            }
    }

    static func payableScore(in normalized: String) -> Int {
        payableLabels.reduce(0) { score, entry in
            normalized.contains(entry.0) ? max(score, entry.1) : score
        }
    }

    /// Once a labelled total exists, low-score line-item prices are not honest
    /// alternatives. Unlabelled screenshots keep a narrow score band because
    /// two prominent currency amounts can genuinely be ambiguous.
    static func credibleAmountValues(_ amounts: [RankedAmount]) -> [Decimal] {
        guard let best = amounts.first else { return [] }
        let credible: [RankedAmount]
        if best.isLabelled {
            credible = amounts.filter { $0.isLabelled && $0.score >= best.score - 45 }
        } else {
            credible = amounts.filter { $0.score >= max(20, best.score - 20) }
        }
        return unique(credible.map(\.value))
    }

    static func nonPayableScore(in normalized: String) -> Int {
        nonPayableLabels.reduce(0) { score, entry in
            normalized.contains(entry.0) ? min(score, entry.1) : score
        }
    }

    static func isInclusivePayableLine(_ normalized: String) -> Bool {
        let explicitlyInclusive = containsAny(
            ["incl.", "incl ", "including", "inclusive", "含税", "含稅", "已含"],
            in: normalized
        )
        let includedCharge = containsAny(
            ["gst", "sst", "vat", " tax", "service charge", "服务费", "服務費",
             "caj perkhidmatan", "cukai"],
            in: normalized
        )
        return explicitlyInclusive && includedCharge
    }

    /// Extracts currency-shaped numbers and repairs only the two OCR confusions
    /// that are safe inside an otherwise numeric token (`O` -> `0`, `I/l` -> `1`).
    static func moneyTokens(in line: String, locale: Locale) -> [MoneyToken] {
        let pattern = #"(?<![0-9.,:])[-−]?(?:[0-9OoIl]{1,3}(?:[ '’][0-9OoIl]{3})+(?:[.,][0-9OoIl]{1,2})?|[0-9OoIl]+(?:[.,][0-9OoIl]+)*)(?![0-9.,:])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        return regex.matches(in: line, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: line) else { return nil }
            let raw = String(line[swiftRange])
            guard raw.contains(where: \.isNumber) else { return nil }
            let repaired = raw
                .replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "o", with: "0")
                .replacingOccurrences(of: "I", with: "1")
                .replacingOccurrences(of: "l", with: "1")
            guard let parsed = parseMoneyToken(repaired, locale: locale) else { return nil }
            return MoneyToken(
                value: parsed.value,
                range: match.range,
                hasFraction: parsed.hasFraction,
                digitCount: repaired.filter(\.isNumber).count
            )
        }
    }

    static func parseMoneyToken(
        _ raw: String,
        locale: Locale
    ) -> (value: Decimal, hasFraction: Bool)? {
        var token = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "−", with: "-")
        guard !token.hasPrefix("-") else { return nil }
        token.removeAll(where: { $0 == "+" })
        guard !token.isEmpty else { return nil }

        let dotOffsets = token.indices.filter { token[$0] == "." }
        let commaOffsets = token.indices.filter { token[$0] == "," }
        let separatorOffsets = dotOffsets + commaOffsets
        var decimalOffset: String.Index?

        if let rightmost = separatorOffsets.max() {
            let fractionCount = token.distance(from: token.index(after: rightmost), to: token.endIndex)
            if fractionCount == 1 || fractionCount == 2 {
                decimalOffset = rightmost
            } else if separatorOffsets.count == 1,
                      fractionCount != 3,
                      String(token[rightmost]) == (locale.decimalSeparator ?? ".") {
                decimalOffset = rightmost
            }
        }

        var normalized = ""
        for index in token.indices {
            let character = token[index]
            if character.isNumber {
                normalized.append(character)
            } else if let decimalOffset, index == decimalOffset {
                normalized.append(".")
            } else if character != "." && character != "," {
                return nil
            }
        }

        guard let value = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return nil }
        return (value, decimalOffset != nil)
    }

    static func isPercentage(_ range: NSRange, in line: String) -> Bool {
        guard let swiftRange = Range(range, in: line) else { return false }
        let tail = line[swiftRange.upperBound...].drop(while: \.isWhitespace)
        return tail.first == "%"
    }

    static func isMostlyAmount(_ line: String) -> Bool {
        let residue = line.unicodeScalars.filter { scalar in
            !CharacterSet.decimalDigits.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet(charactersIn: ".,:'’$€£¥-−").contains(scalar)
        }
        let letters = residue.filter { CharacterSet.letters.contains($0) }
        return letters.count <= 3
    }

    // MARK: - Merchant

    static func rankedMerchants(in lines: [String]) -> [RankedText] {
        var candidates: [RankedText] = []

        for (index, rawLine) in lines.enumerated() {
            let extracted = explicitMerchant(from: rawLine)
            let line = cleanMerchant(extracted ?? rawLine)
            let normalized = normalizedLine(line)
            guard !line.isEmpty, line.count <= 72 else { continue }
            guard line.filter(\.isLetter).count >= 3 else { continue }

            var score = max(0, 45 - index * 4)
            if extracted != nil { score += 110 }
            if containsAny(["pte ltd", "private limited", "sdn bhd", "berhad", "co-op",
                            "company", "enterprise", "restaurant", "cafe", "café"],
                           in: normalized) {
                score += 35
            }
            if line == line.uppercased(), line != line.lowercased() { score += 9 }
            if (3...40).contains(line.count) { score += 8 }

            if containsAny(genericMerchantLines, in: normalized) { score -= 150 }
            if payableScore(in: normalized) > 0
                || containsAny(
                    ["subtotal", "sub total", "subjumlah", "gst", "sst", "vat", "tax",
                     "change", "baki", "tendered", "discount", "service charge", "points",
                     "balance", "total items", "total qty", "小计", "小計", "找零"],
                    in: normalized
                ) {
                score -= 150
            }
            if containsAny(identifierLabels, in: normalized) { score -= 110 }
            if containsAny(["www.", "http", "@", "gst reg", "sst reg", "company reg",
                            "cashier", "server", "table", "counter", "copy"], in: normalized) {
                score -= 100
            }
            if looksLikeAddress(normalized) { score -= 90 }
            if !moneyTokens(in: line, locale: Locale(identifier: "en_SG")).isEmpty {
                score -= 80
            }
            if dateAndTimeRanges(in: line).contains(where: { $0.length > 0 }) { score -= 90 }
            let letterCount = line.filter(\.isLetter).count
            if letterCount * 2 < line.count { score -= 80 }

            if score >= 20 {
                candidates.append(RankedText(value: line, lineIndex: index, score: score))
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            return lhs.value < rhs.value
        }
    }

    static func explicitMerchant(from line: String) -> String? {
        let patterns = [
            #"(?i)^\s*(?:paid\s+to|payment\s+to|merchant|payee|store)\s*[:\-]?\s+(.+)$"#,
            #"^\s*(?:商户|商戶|收款方|商家)\s*[:：\-]?\s*(.+)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: full),
                  match.numberOfRanges == 2,
                  let range = Range(match.range(at: 1), in: line) else { continue }
            return String(line[range])
        }
        return nil
    }

    static func cleanMerchant(_ value: String) -> String {
        cleanLine(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*-=_~|•·#.:, \t"))
    }

    static func looksLikeAddress(_ normalized: String) -> Bool {
        containsAny(
            [" road", " rd", " street", " st ", " avenue", " ave", " boulevard",
             " lane", " drive", "jalan ", "jln ", "lorong ", "taman ", "singapore ",
             "malaysia ", " johor", " selangor", " kuala lumpur", " unit ", "level "],
            in: " " + normalized + " "
        )
    }

    // MARK: - Dates
}
