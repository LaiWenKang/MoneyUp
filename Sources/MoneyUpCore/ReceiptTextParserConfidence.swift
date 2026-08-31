import Foundation

extension ReceiptTextParser {
    struct CandidateDetails {
        let amounts: [ReceiptCandidate<Decimal>]
        let merchants: [ReceiptCandidate<String>]
        let dates: [ReceiptCandidate<Date>]
        let categories: [ReceiptCandidate<ReceiptCategoryHint>]
    }

    static func cleanedInput(
        lines: [String],
        ocrConfidence: Float?,
        lineConfidences: [Float]?
    ) -> CleanedReceiptInput {
        let hasAlignedConfidences = lineConfidences?.count == lines.count
        var cleaned: [String] = []
        var cleanedConfidences: [Float] = []
        cleaned.reserveCapacity(lines.count)
        if hasAlignedConfidences {
            cleanedConfidences.reserveCapacity(lines.count)
        }
        for (index, line) in lines.enumerated() {
            let value = cleanLine(line)
            guard !value.isEmpty else { continue }
            cleaned.append(value)
            if hasAlignedConfidences, let confidence = lineConfidences?[index] {
                cleanedConfidences.append(sanitizeOCRConfidence(confidence) ?? 0)
            }
        }
        return CleanedReceiptInput(
            lines: cleaned,
            ocrConfidence: sanitizeOCRConfidence(ocrConfidence),
            lineConfidences: hasAlignedConfidences ? cleanedConfidences : nil
        )
    }

    static func candidateDetails(
        amounts: [RankedAmount],
        merchants: [RankedText],
        dates: [RankedDate],
        categories: [RankedCategory],
        input: CleanedReceiptInput
    ) -> CandidateDetails {
        CandidateDetails(
            amounts: amountDetails(amounts, input: input),
            merchants: merchantDetails(merchants, input: input),
            dates: dateDetails(dates, input: input),
            categories: categoryDetails(categories, input: input)
        )
    }

    static func amountDetails(
        _ amounts: [RankedAmount],
        input: CleanedReceiptInput
    ) -> [ReceiptCandidate<Decimal>] {
        uniqueCandidates(credibleAmounts(amounts).map { amount in
            candidate(
                value: amount.value,
                score: amount.score,
                parserConfidence: amountConfidence(for: amount),
                evidence: amount.evidence,
                ocrConfidence: fieldOCRConfidence(
                    lineIndex: amount.lineIndex,
                    lineConfidences: input.lineConfidences,
                    fallback: input.ocrConfidence
                )
            )
        })
    }

    static func merchantDetails(
        _ merchants: [RankedText],
        input: CleanedReceiptInput
    ) -> [ReceiptCandidate<String>] {
        uniqueCandidates(merchants.map { merchant in
            candidate(
                value: merchant.value,
                score: merchant.score,
                parserConfidence: merchantConfidence(for: merchant),
                evidence: merchant.evidence,
                ocrConfidence: fieldOCRConfidence(
                    lineIndex: merchant.lineIndex,
                    lineConfidences: input.lineConfidences,
                    fallback: input.ocrConfidence
                )
            )
        })
    }

    static func dateDetails(
        _ dates: [RankedDate],
        input: CleanedReceiptInput
    ) -> [ReceiptCandidate<Date>] {
        uniqueCandidates(dates.map { date in
            candidate(
                value: date.value,
                score: date.score,
                parserConfidence: dateConfidence(for: date),
                evidence: date.evidence,
                ocrConfidence: fieldOCRConfidence(
                    lineIndex: date.lineIndex,
                    lineConfidences: input.lineConfidences,
                    fallback: input.ocrConfidence
                )
            )
        })
    }

    static func categoryDetails(
        _ categories: [RankedCategory],
        input: CleanedReceiptInput
    ) -> [ReceiptCandidate<ReceiptCategoryHint>] {
        categories.map { category in
            candidate(
                value: category.value,
                score: category.score,
                parserConfidence: categoryConfidence(for: category),
                evidence: category.evidence,
                ocrConfidence: input.lineConfidences?.min() ?? input.ocrConfidence
            )
        }
    }

    static func amountConfidence(for amount: RankedAmount) -> CaptureConfidence {
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

    static func merchantConfidence(for merchant: RankedText) -> CaptureConfidence {
        if merchant.evidence.contains(.explicitMerchantLabel) {
            return .high
        }
        if merchant.evidence.contains(.businessNameMarker) || merchant.score >= 60 {
            return .medium
        }
        return .low
    }

    static func dateConfidence(for date: RankedDate) -> CaptureConfidence {
        if date.evidence.contains(.transactionDateLabel) {
            return .high
        }
        if date.evidence.contains(.genericDateLabel) || date.score >= 50 {
            return .medium
        }
        return .low
    }

    static func categoryConfidence(for category: RankedCategory) -> CaptureConfidence {
        if category.score >= 3 { return .high }
        if category.score == 2 { return .medium }
        return .low
    }

    static func candidate<Value: Equatable & Sendable>(
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
                confidence = min(parserConfidence, .medium)
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

    static func sanitizeOCRConfidence(_ value: Float?) -> Float? {
        guard let value else { return nil }
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    static func fieldOCRConfidence(
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

    static func confidenceBand(for ocrConfidence: Float?) -> CaptureConfidence? {
        guard let ocrConfidence else { return nil }
        if ocrConfidence < 0.5 { return .low }
        if ocrConfidence < 0.8 { return .medium }
        return .high
    }

    static func overallConfidence(
        _ values: CaptureConfidence?...
    ) -> CaptureConfidence? {
        values.compactMap { $0 }.min()
    }

    static func uniqueCandidates<Value: Equatable & Sendable>(
        _ candidates: [ReceiptCandidate<Value>]
    ) -> [ReceiptCandidate<Value>] {
        candidates.reduce(into: []) { result, candidate in
            if !result.contains(where: { $0.value == candidate.value }) {
                result.append(candidate)
            }
        }
    }
}
