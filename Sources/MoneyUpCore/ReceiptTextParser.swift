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

/// An inspectable parser signal that contributed to a receipt candidate.
///
/// Evidence is intentionally semantic rather than a copy of OCR text so a
/// caller can explain the suggestion without retaining receipt contents.
public enum ReceiptCandidateEvidence: String, Equatable, Hashable, Sendable {
    case payableAmountLabel
    case precedingPayableAmountLabel
    case currencyMarker
    case fractionalAmount
    case unlabelledAmount
    case explicitMerchantLabel
    case businessNameMarker
    case receiptHeaderPosition
    case uppercaseMerchantText
    case transactionDateLabel
    case genericDateLabel
    case timeComponent
    case plausibleDate
    case categoryKeywordMatch
    case multipleCategoryKeywordMatches
    case unscoredCompatibilityValue
    case lowOCRConfidence
    case moderateOCRConfidence
    case strongOCRConfidence
}

/// A best-first receipt suggestion together with the deterministic signals
/// that produced it. Scores are relative only to candidates for the same
/// field and are not percentages or probabilities.
public struct ReceiptCandidate<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let score: Int
    public let confidence: CaptureConfidence
    public let evidence: [ReceiptCandidateEvidence]

    public init(
        value: Value,
        score: Int,
        confidence: CaptureConfidence,
        evidence: [ReceiptCandidateEvidence]
    ) {
        self.value = value
        self.score = score
        self.confidence = confidence
        self.evidence = evidence
    }
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
    public let ocrConfidence: Float?
    public let overallConfidence: CaptureConfidence?
    public let amountCandidateDetails: [ReceiptCandidate<Decimal>]
    public let merchantCandidateDetails: [ReceiptCandidate<String>]
    public let dateCandidateDetails: [ReceiptCandidate<Date>]
    public let categoryCandidateDetails: [ReceiptCandidate<ReceiptCategoryHint>]

    public init(
        draft: TransactionDraft,
        amountCandidates: [Decimal],
        merchantCandidates: [String],
        dateCandidates: [Date],
        categoryHint: ReceiptCategoryHint?,
        noteCandidate: String?,
        ocrConfidence: Float? = nil,
        overallConfidence: CaptureConfidence? = nil,
        amountCandidateDetails: [ReceiptCandidate<Decimal>]? = nil,
        merchantCandidateDetails: [ReceiptCandidate<String>]? = nil,
        dateCandidateDetails: [ReceiptCandidate<Date>]? = nil,
        categoryCandidateDetails: [ReceiptCandidate<ReceiptCategoryHint>]? = nil
    ) {
        self.draft = draft
        self.amountCandidates = amountCandidates
        self.merchantCandidates = merchantCandidates
        self.dateCandidates = dateCandidates
        self.categoryHint = categoryHint
        self.noteCandidate = noteCandidate
        self.ocrConfidence = ocrConfidence
        self.overallConfidence = overallConfidence
        self.amountCandidateDetails = amountCandidateDetails ?? amountCandidates.map {
            ReceiptCandidate(
                value: $0,
                score: 0,
                confidence: .low,
                evidence: [.unscoredCompatibilityValue]
            )
        }
        self.merchantCandidateDetails = merchantCandidateDetails ?? merchantCandidates.map {
            ReceiptCandidate(
                value: $0,
                score: 0,
                confidence: .low,
                evidence: [.unscoredCompatibilityValue]
            )
        }
        self.dateCandidateDetails = dateCandidateDetails ?? dateCandidates.map {
            ReceiptCandidate(
                value: $0,
                score: 0,
                confidence: .low,
                evidence: [.unscoredCompatibilityValue]
            )
        }
        if let categoryCandidateDetails {
            self.categoryCandidateDetails = categoryCandidateDetails
        } else if let categoryHint {
            self.categoryCandidateDetails = [ReceiptCandidate(
                value: categoryHint,
                score: 0,
                confidence: .low,
                evidence: [.unscoredCompatibilityValue]
            )]
        } else {
            self.categoryCandidateDetails = []
        }
    }
}

/// Turns OCR lines from a receipt photo or payment screenshot into a draft.
///
/// Parsing is local, deterministic, and intentionally explainable. Labelled
/// payable amounts outrank everything else; subtotal, tax, change, tendered
/// cash, balances, identifiers, dates, times, percentages, and card tails are
/// explicitly demoted or rejected.
public enum ReceiptTextParser {
    private struct RankedAmount {
        let value: Decimal
        let lineIndex: Int
        let rangeLocation: Int
        let score: Int
        let isLabelled: Bool
        let evidence: [ReceiptCandidateEvidence]
    }

    private struct RankedText {
        let value: String
        let lineIndex: Int
        let score: Int
        let evidence: [ReceiptCandidateEvidence]
    }

    private struct RankedDate {
        let value: Date
        let lineIndex: Int
        let score: Int
        let evidence: [ReceiptCandidateEvidence]
    }

    private struct RankedCategory {
        let value: ReceiptCategoryHint
        let score: Int
        let priority: Int
        let evidence: [ReceiptCandidateEvidence]
    }

    private struct MoneyToken {
        let value: Decimal
        let range: NSRange
        let hasFraction: Bool
        let digitCount: Int
    }

    private static let payableLabels: [(String, Int)] = [
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
    private static let nonPayableLabels: [(String, Int)] = [
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

    private static let identifierLabels = [
        "phone", "tel", "mobile", "fax", "order no", "order #", "invoice no",
        "invoice #", "receipt no", "receipt #", "transaction id", "txn id",
        "reference", "ref no", "auth", "approval", "terminal", "merchant id",
        "member", "loyalty", "table no", "queue no", "pager", "card no",
        "acct", "account no", "电话", "電話", "订单", "訂單", "单号", "單號"
    ]

    private static let currencyMarkers = [
        "s$", "sgd", "rm", "myr", "usd", "us$", "aud", "eur", "gbp",
        "cny", "rmb", "hkd", "$", "€", "£", "¥"
    ]

    private static let dateExclusionLabels = [
        "best before", "use by", "expiry", "expires", "expiration", "valid thru",
        "valid through", "member since", "card expiry", "manufactured",
        "有效期", "保质期", "保質期", "到期", "生产日期", "生產日期"
    ]

    private static let genericMerchantLines = [
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
        accounts: [LedgerAccount] = [],
        ocrConfidence: Float? = nil,
        ocrLineConfidences: [Float]? = nil
    ) -> TransactionDraft {
        analyze(
            fromLines: lines,
            now: now,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst,
            locale: locale,
            accounts: accounts,
            ocrConfidence: ocrConfidence,
            ocrLineConfidences: ocrLineConfidences
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
        accounts: [LedgerAccount] = [],
        ocrConfidence: Float? = nil,
        ocrLineConfidences: [Float]? = nil
    ) -> ReceiptParseResult {
        let hasAlignedLineConfidences = ocrLineConfidences?.count == lines.count
        var cleaned: [String] = []
        var cleanedLineConfidences: [Float] = []
        cleaned.reserveCapacity(lines.count)
        if hasAlignedLineConfidences {
            cleanedLineConfidences.reserveCapacity(lines.count)
        }
        for (index, line) in lines.enumerated() {
            let value = cleanLine(line)
            guard !value.isEmpty else { continue }
            cleaned.append(value)
            if hasAlignedLineConfidences,
               let confidence = ocrLineConfidences?[index] {
                cleanedLineConfidences.append(sanitizeOCRConfidence(confidence) ?? 0)
            }
        }

        let normalizedOCRConfidence = sanitizeOCRConfidence(ocrConfidence)
        let normalizedLineConfidences: [Float]? = hasAlignedLineConfidences
            ? cleanedLineConfidences : nil

        let amounts = rankedAmounts(in: cleaned, locale: locale)
        let merchants = rankedMerchants(in: cleaned)
        let dates = rankedDates(
            in: cleaned,
            now: now,
            calendar: calendar,
            prefersDayFirst: prefersDayFirst
        )
        let categories = rankedCategories(
            in: cleaned,
            merchant: merchants.first?.value
        )
        let inferredCategory = categories.first?.value
        let categoryID = inferredCategory.flatMap {
            Self.categoryID(for: $0, in: accounts)
        }

        let amountDetails = uniqueCandidates(
            credibleAmounts(amounts).map {
                candidate(
                    value: $0.value,
                    score: $0.score,
                    parserConfidence: amountConfidence(for: $0),
                    evidence: $0.evidence,
                    ocrConfidence: fieldOCRConfidence(
                        lineIndex: $0.lineIndex,
                        lineConfidences: normalizedLineConfidences,
                        fallback: normalizedOCRConfidence
                    )
                )
            }
        )
        let merchantDetails = uniqueCandidates(
            merchants.map {
                candidate(
                    value: $0.value,
                    score: $0.score,
                    parserConfidence: merchantConfidence(for: $0),
                    evidence: $0.evidence,
                    ocrConfidence: fieldOCRConfidence(
                        lineIndex: $0.lineIndex,
                        lineConfidences: normalizedLineConfidences,
                        fallback: normalizedOCRConfidence
                    )
                )
            }
        )
        let dateDetails = uniqueCandidates(
            dates.map {
                candidate(
                    value: $0.value,
                    score: $0.score,
                    parserConfidence: dateConfidence(for: $0),
                    evidence: $0.evidence,
                    ocrConfidence: fieldOCRConfidence(
                        lineIndex: $0.lineIndex,
                        lineConfidences: normalizedLineConfidences,
                        fallback: normalizedOCRConfidence
                    )
                )
            }
        )
        let categoryDetails = categories.map {
            candidate(
                value: $0.value,
                score: $0.score,
                parserConfidence: categoryConfidence(for: $0),
                evidence: $0.evidence,
                ocrConfidence: normalizedLineConfidences?.min()
                    ?? normalizedOCRConfidence
            )
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
            amountCandidates: amountDetails.map(\.value),
            merchantCandidates: merchantDetails.map(\.value),
            dateCandidates: dateDetails.map(\.value),
            categoryHint: inferredCategory,
            noteCandidate: noteCandidate(in: cleaned),
            ocrConfidence: normalizedOCRConfidence,
            overallConfidence: overallConfidence(
                confidenceBand(
                    for: normalizedLineConfidences?.min()
                        ?? normalizedOCRConfidence
                ),
                amountDetails.first?.confidence,
                merchantDetails.first?.confidence,
                dateDetails.first?.confidence,
                categoryDetails.first?.confidence
            ),
            amountCandidateDetails: amountDetails,
            merchantCandidateDetails: merchantDetails,
            dateCandidateDetails: dateDetails,
            categoryCandidateDetails: categoryDetails
        )
    }

    // MARK: - Amounts

    private static func rankedAmounts(
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
                var evidence: [ReceiptCandidateEvidence] = []
                if labelScore > 0 {
                    score += labelScore
                    isLabelled = true
                    evidence.append(.payableAmountLabel)
                } else if previousLabelScore > 0, isMostlyAmount(line) {
                    score += previousLabelScore - 10
                    isLabelled = true
                    evidence.append(.precedingPayableAmountLabel)
                }

                score += exclusionScore
                if hasCurrency {
                    score += 24
                    evidence.append(.currencyMarker)
                }
                if token.hasFraction {
                    score += 20
                    evidence.append(.fractionalAmount)
                }
                if !isLabelled {
                    evidence.append(.unlabelledAmount)
                }
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
                        isLabelled: isLabelled,
                        evidence: evidence
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

    private static func payableScore(in normalized: String) -> Int {
        payableLabels.reduce(0) { score, entry in
            normalized.contains(entry.0) ? max(score, entry.1) : score
        }
    }

    /// Once a labelled total exists, low-score line-item prices are not honest
    /// alternatives. Unlabelled screenshots keep a narrow score band because
    /// two prominent currency amounts can genuinely be ambiguous.
    private static func credibleAmounts(_ amounts: [RankedAmount]) -> [RankedAmount] {
        guard let best = amounts.first else { return [] }
        let credible: [RankedAmount]
        if best.isLabelled {
            credible = amounts.filter { $0.isLabelled && $0.score >= best.score - 45 }
        } else {
            credible = amounts.filter { $0.score >= max(20, best.score - 20) }
        }
        return credible
    }

    private static func nonPayableScore(in normalized: String) -> Int {
        nonPayableLabels.reduce(0) { score, entry in
            normalized.contains(entry.0) ? min(score, entry.1) : score
        }
    }

    private static func isInclusivePayableLine(_ normalized: String) -> Bool {
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
    private static func moneyTokens(in line: String, locale: Locale) -> [MoneyToken] {
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

    private static func parseMoneyToken(
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

    private static func isPercentage(_ range: NSRange, in line: String) -> Bool {
        guard let swiftRange = Range(range, in: line) else { return false }
        let tail = line[swiftRange.upperBound...].drop(while: \.isWhitespace)
        return tail.first == "%"
    }

    private static func isMostlyAmount(_ line: String) -> Bool {
        let residue = line.unicodeScalars.filter { scalar in
            !CharacterSet.decimalDigits.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet(charactersIn: ".,:'’$€£¥-−").contains(scalar)
        }
        let letters = residue.filter { CharacterSet.letters.contains($0) }
        return letters.count <= 3
    }

    // MARK: - Merchant

    private static func rankedMerchants(in lines: [String]) -> [RankedText] {
        var candidates: [RankedText] = []

        for (index, rawLine) in lines.enumerated() {
            let extracted = explicitMerchant(from: rawLine)
            let line = cleanMerchant(extracted ?? rawLine)
            let normalized = normalizedLine(line)
            guard !line.isEmpty, line.count <= 72 else { continue }
            guard line.filter(\.isLetter).count >= 3 else { continue }

            var score = max(0, 45 - index * 4)
            var evidence: [ReceiptCandidateEvidence] = []
            if score > 0 {
                evidence.append(.receiptHeaderPosition)
            }
            if extracted != nil {
                score += 110
                evidence.append(.explicitMerchantLabel)
            }
            let hasBusinessMarker = containsAny(
                ["pte ltd", "private limited", "sdn bhd", "berhad", "co-op",
                 "company", "enterprise", "restaurant", "cafe", "café"],
                in: normalized
            )
            if hasBusinessMarker {
                score += 35
                evidence.append(.businessNameMarker)
            }
            if line == line.uppercased(), line != line.lowercased() {
                score += 9
                evidence.append(.uppercaseMerchantText)
            }
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
                candidates.append(
                    RankedText(
                        value: line,
                        lineIndex: index,
                        score: score,
                        evidence: evidence
                    )
                )
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            return lhs.value < rhs.value
        }
    }

    private static func explicitMerchant(from line: String) -> String? {
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

    private static func cleanMerchant(_ value: String) -> String {
        cleanLine(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*-=_~|•·#.:, \t"))
    }

    private static func looksLikeAddress(_ normalized: String) -> Bool {
        containsAny(
            [" road", " rd", " street", " st ", " avenue", " ave", " boulevard",
             " lane", " drive", "jalan ", "jln ", "lorong ", "taman ", "singapore ",
             "malaysia ", " johor", " selangor", " kuala lumpur", " unit ", "level "],
            in: " " + normalized + " "
        )
    }

    // MARK: - Dates

    private static func rankedDates(
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
            var evidence: [ReceiptCandidateEvidence] = [.plausibleDate]
            let hasTransactionDateLabel = containsAny(
                ["transaction date", "payment date", "purchase date", "paid on",
                 "date/time", "datetime", "交易日期", "付款日期", "消费日期"],
                in: normalized
            )
            if hasTransactionDateLabel {
                score += 70
                evidence.append(.transactionDateLabel)
            } else if containsAny(["date", "日期"], in: normalized) {
                score += 25
                evidence.append(.genericDateLabel)
            }
            if timeComponents(in: line) != nil {
                score += 10
                evidence.append(.timeComponent)
            }
            score += max(0, 10 - index)
            candidates.append(
                RankedDate(
                    value: value,
                    lineIndex: index,
                    score: score,
                    evidence: evidence
                )
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
            return lhs.value > rhs.value
        }
    }

    private static func parsedDate(
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

        let parsedTime = timeComponents(in: line)
        if let time = parsedTime {
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
        if let parsedTime {
            let resolvedTime = calendar.dateComponents(
                [.hour, .minute, .second],
                from: date
            )
            guard resolvedTime.hour == parsedTime.hour,
                  resolvedTime.minute == parsedTime.minute,
                  resolvedTime.second == parsedTime.second else {
                // Calendar normalizes nonexistent local times during a DST
                // spring-forward gap. That is not the time printed by the
                // receipt, so fail closed instead of raising confidence.
                return nil
            }
        }
        return date
    }

    private static func shortNumericDate(
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

    private static func namedMonthDate(in line: String, calendar: Calendar) -> DateComponents? {
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

    private static func validDateComponents(
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

    private static func normalizedYear(_ text: String) -> Int? {
        guard let value = Int(text) else { return nil }
        return text.count == 2 ? 2000 + value : value
    }

    private static func monthNumber(_ text: String) -> Int? {
        let prefix = String(text.lowercased().prefix(3))
        return [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ][prefix]
    }

    private static func timeComponents(in line: String) -> DateComponents? {
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

    private static func dateAndTimeRanges(in line: String) -> [NSRange] {
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

    private static func rankedCategories(
        in lines: [String],
        merchant: String?
    ) -> [RankedCategory] {
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

        return rules.enumerated().compactMap { priority, rule -> RankedCategory? in
            let hits = rule.1.filter { text.contains($0) }.count
            guard hits > 0 else { return nil }
            var evidence: [ReceiptCandidateEvidence] = [.categoryKeywordMatch]
            if hits > 1 {
                evidence.append(.multipleCategoryKeywordMatches)
            }
            return RankedCategory(
                value: rule.0,
                score: hits,
                priority: priority,
                evidence: evidence
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.priority < rhs.priority
        }
    }

    private static func categoryID(
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

    private static func noteCandidate(in lines: [String]) -> String? {
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

    private static func amountConfidence(
        for amount: RankedAmount
    ) -> CaptureConfidence {
        if amount.evidence.contains(.payableAmountLabel)
            || amount.evidence.contains(.precedingPayableAmountLabel) {
            return .high
        }
        if amount.evidence.contains(.currencyMarker)
            && amount.evidence.contains(.fractionalAmount) {
            return .medium
        }
        return .low
    }

    private static func merchantConfidence(
        for merchant: RankedText
    ) -> CaptureConfidence {
        if merchant.evidence.contains(.explicitMerchantLabel) {
            return .high
        }
        if merchant.evidence.contains(.businessNameMarker) || merchant.score >= 60 {
            return .medium
        }
        return .low
    }

    private static func dateConfidence(
        for date: RankedDate
    ) -> CaptureConfidence {
        if date.evidence.contains(.transactionDateLabel) {
            return .high
        }
        if date.evidence.contains(.genericDateLabel) || date.score >= 50 {
            return .medium
        }
        return .low
    }

    private static func categoryConfidence(
        for category: RankedCategory
    ) -> CaptureConfidence {
        if category.score >= 3 { return .high }
        if category.score == 2 { return .medium }
        return .low
    }

    private static func candidate<Value: Equatable & Sendable>(
        value: Value,
        score: Int,
        parserConfidence: CaptureConfidence,
        evidence parserEvidence: [ReceiptCandidateEvidence],
        ocrConfidence: Float?
    ) -> ReceiptCandidate<Value> {
        var evidence = parserEvidence
        let confidence: CaptureConfidence
        if let ocrConfidence {
            if ocrConfidence < 0.5 {
                confidence = .low
                evidence.append(.lowOCRConfidence)
            } else if ocrConfidence < 0.8 {
                confidence = minimum(parserConfidence, .medium)
                evidence.append(.moderateOCRConfidence)
            } else {
                confidence = parserConfidence
                evidence.append(.strongOCRConfidence)
            }
        } else {
            confidence = parserConfidence
        }
        return ReceiptCandidate(
            value: value,
            score: score,
            confidence: confidence,
            evidence: evidence
        )
    }

    private static func sanitizeOCRConfidence(_ value: Float?) -> Float? {
        guard let value else { return nil }
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func fieldOCRConfidence(
        lineIndex: Int,
        lineConfidences: [Float]?,
        fallback: Float?
    ) -> Float? {
        guard let lineConfidences,
              lineConfidences.indices.contains(lineIndex) else {
            return fallback
        }
        return lineConfidences[lineIndex]
    }

    private static func confidenceBand(for ocrConfidence: Float?)
        -> CaptureConfidence? {
        guard let ocrConfidence else { return nil }
        if ocrConfidence < 0.5 { return .low }
        if ocrConfidence < 0.8 { return .medium }
        return .high
    }

    private static func overallConfidence(
        _ values: CaptureConfidence?...
    ) -> CaptureConfidence? {
        values.compactMap { $0 }.min()
    }

    private static func minimum(
        _ lhs: CaptureConfidence,
        _ rhs: CaptureConfidence
    ) -> CaptureConfidence {
        min(lhs, rhs)
    }

    private static func uniqueCandidates<Value: Equatable & Sendable>(
        _ candidates: [ReceiptCandidate<Value>]
    ) -> [ReceiptCandidate<Value>] {
        candidates.reduce(into: []) { result, candidate in
            if !result.contains(where: { $0.value == candidate.value }) {
                result.append(candidate)
            }
        }
    }

    private static func cleanLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLine(_ value: String) -> String {
        TextScanner.normalized(cleanLine(value)).lowercased()
    }

    private static func containsAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains(where: { haystack.contains($0) })
    }

    private static func hasCurrencyMarker(in text: String) -> Bool {
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

    private static func captures(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: full) else { return nil }
        return (1..<match.numberOfRanges).compactMap { capture(match, at: $0, in: text) }
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        at index: Int,
        in text: String
    ) -> String? {
        guard index < match.numberOfRanges,
              match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func limited(_ value: String, to maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
