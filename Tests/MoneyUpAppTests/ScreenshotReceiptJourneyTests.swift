import Foundation
import MoneyUpCore
@testable import MoneyUp
import XCTest

final class ScreenshotReceiptJourneyTests: XCTestCase {
    func testNativeVisionReadsScreenshotAmountsAndKeepsWeakFallbackExplicit() async throws {
        let calendar = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "Asia/Singapore")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T04:00:00Z"))
        var samples: [[String: Any]] = []
        for style in ScreenshotReceiptFixture.Style.allCases {
            let data = try ScreenshotReceiptFixture.png(style: style)
            let started = ContinuousClock.now
            let recognition = try await ReceiptScanner.recognize(inImageData: data)
            let result = ReceiptTextParser.analyze(fromLines: recognition.lines, now: now, calendar: calendar,
                ocrConfidence: recognition.meanConfidence, ocrLineConfidences: recognition.lineConfidences,
                requiresExplicitReview: recognition.requiresExplicitReview)
            let expected = try XCTUnwrap(Decimal(string: style == .chinese ? "23.45" : style == .itemized ? "38.00" : "12.34"))
            XCTAssertTrue(result.amountCandidates.contains(expected), "\(style): expected amount must remain reviewable")
            if !result.requiresExplicitReview {
                XCTAssertEqual(result.draft.amount, expected)
                XCTAssertEqual(result.currencyEvidence.identifiedCurrency, try CurrencyCode("SGD"))
                XCTAssertNotEqual(result.amountCandidateDetails.first?.confidence, .low)
            }
            let duration = started.duration(to: ContinuousClock.now).components
            samples.append(["style": style.rawValue, "elapsed_ms": Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                "requires_explicit_review": result.requiresExplicitReview, "date_read": result.draft.occurredAt != nil])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "screenshot-receipt-" + style.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        evidence.name = "screenshot-ocr-results.json"; evidence.lifetime = .keepAlways; add(evidence)
    }

    func testFastRecognitionUsesFieldConfidenceAndPayableEvidence() {
        let accepted = ReceiptRecognitionResult(lines: ["HARBOUR CAFE", "Amount paid SGD 12.34"],
            meanConfidence: 0.5, lineConfidences: [0.5, 0.5])
        XCTAssertTrue(ReceiptRecognitionAcceptancePolicy.accepts(accepted))
        let weakAmount = ReceiptRecognitionResult(lines: accepted.lines, meanConfidence: 0.9, lineConfidences: [1, 0.3])
        XCTAssertFalse(ReceiptRecognitionAcceptancePolicy.accepts(weakAmount))
        XCTAssertFalse(ReceiptRecognitionAcceptancePolicy.accepts(ReceiptRecognitionResult(
            lines: ["Available balance SGD 12.34", "Reference 4829103756"], meanConfidence: 1, lineConfidences: [1, 1])))
        XCTAssertFalse(ReceiptRecognitionAcceptancePolicy.accepts(ReceiptRecognitionResult(lines: accepted.lines, meanConfidence: .nan)))
    }

    @MainActor
    func testPartialRecognitionAuthoritySurvivesBoundingAndParser() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let recognition = ReceiptRecognitionResult(lines: ["HARBOUR CAFE", "TOTAL SGD 12.34"],
            meanConfidence: 0.5, lineConfidences: [0.5, 0.5], requiresExplicitReview: true)
        let model = fixture.model(receiptRecognizer: { _ in recognition })
        XCTAssertTrue(AppModel.boundedReceiptRecognition(recognition).requiresExplicitReview)
        let result = try await model.receiptAnalysis(from: Data([0]), prefersDayFirst: true)
        XCTAssertEqual(result?.draft.amount, Decimal(string: "12.34"))
        XCTAssertEqual(result?.requiresExplicitReview, true)
        XCTAssertEqual(result?.ocrConfidence, 0.5, "Review authority must not falsify observed confidence")
        await fixture.store.close()
    }

    func testChineseBalancesAndReferencesAreNotOfferedAsPayableAmounts() {
        let result = ReceiptTextParser.analyze(fromLines: ["支付成功", "实付 SGD 23.45", "商户：星河餐厅",
            "账户余额 SGD 9876.54", "交易编号：4829103756"])
        XCTAssertEqual(result.draft.amount, Decimal(string: "23.45"))
        XCTAssertFalse(result.amountCandidates.contains(Decimal(string: "9876.54")!))
        XCTAssertFalse(result.amountCandidates.contains(Decimal(4_829_103_756)))
    }
}
