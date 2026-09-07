import Foundation
import MoneyUpCore

/// Fast OCR must meet the same field-level admissibility as draft review.
/// Moderate evidence remains moderate; a strong header cannot promote a weak
/// amount. Unlabelled or low-confidence output still needs accurate OCR.
enum ReceiptRecognitionAcceptancePolicy {
    static func accepts(_ result: ReceiptRecognitionResult) -> Bool {
        guard !result.requiresExplicitReview, result.lines.count >= 2, let confidence = result.meanConfidence, confidence >= 0.5 else { return false }
        // Use the authoritative parser as the quality gate so fast OCR and the
        // final parse cannot disagree about decimal commas, grouping, or safe
        // OCR digit repair.
        let parsed = ReceiptTextParser.analyze(
            fromLines: result.lines,
            ocrConfidence: result.meanConfidence,
            ocrLineConfidences: result.lineConfidences
        )
        guard let amountConfidence = parsed.amountCandidateDetails.first?.confidence,
              amountConfidence != .low else {
            return false
        }

        let strongLabels = [
            "grand total", "amount due", "amount payable", "amount paid", "you paid",
            "payment amount", "transfer amount", "jumlah besar", "jumlah bayaran", "jumlah",
            "合计", "合計", "总计", "總計", "应付", "應付", "实付", "實付"
        ]
        let excludedLabelLines = [
            "subtotal", "sub total", "sub-total", "total items", "total qty",
            "total savings", "total discount", "total points", "available balance",
            "account balance", "cash tendered", "change", "subjumlah", "jumlah kecil",
            "jumlah diskaun", "baki", "total gst", "gst total", "total sst",
            "sst total", "total vat", "vat total", "total tax", "tax total",
            "total service charge", "jumlah cukai", "jumlah caj perkhidmatan",
            "税额", "稅額", "服务费", "服務費"
        ]
        if result.lines.contains(where: { rawLine in
            let line = rawLine.lowercased()
            if excludedLabelLines.contains(where: { line.contains($0) }) { return false }
            if strongLabels.contains(where: { line.contains($0) }) { return true }
            return line.contains("total")
        }) {
            return true
        }

        let text = result.lines.joined(separator: " ").lowercased()
        return ["payment successful", "transaction successful", "transfer successful",
                "paid to", "payment to", "transferred to", "sent to"]
            .contains(where: { text.contains($0) })
    }
}
