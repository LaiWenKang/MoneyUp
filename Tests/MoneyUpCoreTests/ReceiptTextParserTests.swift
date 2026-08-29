import Foundation
@testable import MoneyUpCore
import XCTest

final class ReceiptTextParserTests: XCTestCase {
    func testCommaDecimalReceiptUsesLocaleGrammar() {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Boulangerie", "TOTAL 12,50"],
            locale: Locale(identifier: "fr_FR")
        )

        XCTAssertEqual(draft.amount, Decimal(string: "12.50"))
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return try XCTUnwrap(calendar.date(from: components))
    }

    func testReadsGrandTotalRatherThanSubtotalOrTax() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "FAIRPRICE FINEST",
                "313 Somerset",
                "Bread          3.20",
                "Milk           4.50",
                "Subtotal      27.10",
                "GST 9%         2.44",
                "TOTAL         29.54",
                "Cash          50.00",
                "Change        20.46"
            ],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "29.54"))
        XCTAssertEqual(draft.payee, "FAIRPRICE FINEST")
        XCTAssertEqual(draft.kind, .expense)
        XCTAssertEqual(draft.source, .receipt)
    }

    func testReadsChineseReceiptTotal() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "海底捞火锅",
                "小计        168.00",
                "服务费       16.80",
                "合计        184.80",
                "2026年03月18日"
            ],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "184.80"))
        XCTAssertEqual(draft.payee, "海底捞火锅")
        XCTAssertEqual(draft.occurredAt, try date(2026, 3, 18, hour: 0))
    }

    func testReadsTotalPrintedOnTheLineBelowItsLabel() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Cafe Nero", "Amount Due", "12.40"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "12.40"))
    }

    func testIgnoresCardAndPhoneNumbersWhenNoTotalIsLabelled() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "Corner Store",
                "Tel 6581234567",
                "VISA 4111111111111111",
                "8.75"
            ],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "8.75"))
    }

    func testGivesUpRatherThanGuessingWhenNoDecimalAmountExists() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Corner Store", "Tel 6581234567", "Order 88231"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertNil(draft.amount)
    }

    func testRejectsADateFarOutsideThePlausibleRange() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Shop", "Best before 2031/01/01", "TOTAL 5.00"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertNil(draft.occurredAt)
        XCTAssertEqual(draft.amount, Decimal(5))
    }

    func testDayFirstAndMonthFirstReadingsFollowTheLocale() throws {
        let lines = ["Shop", "05/03/2026", "TOTAL 5.00"]

        let dayFirst = ReceiptTextParser.draft(
            fromLines: lines,
            now: try date(2026, 6, 1),
            calendar: calendar,
            prefersDayFirst: true
        )
        let monthFirst = ReceiptTextParser.draft(
            fromLines: lines,
            now: try date(2026, 6, 1),
            calendar: calendar,
            prefersDayFirst: false
        )

        XCTAssertEqual(dayFirst.occurredAt, try date(2026, 3, 5, hour: 0))
        XCTAssertEqual(monthFirst.occurredAt, try date(2026, 5, 3, hour: 0))
    }

    func testUnambiguousDayAboveTwelveOverridesTheLocale() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Shop", "19/03/2026", "TOTAL 5.00"],
            now: try date(2026, 6, 1),
            calendar: calendar,
            prefersDayFirst: false
        )

        XCTAssertEqual(draft.occurredAt, try date(2026, 3, 19, hour: 0))
    }

    func testNonexistentDSTGapTimeFailsClosed() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let now = try XCTUnwrap(losAngeles.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 9,
            hour: 12
        )))

        let result = ReceiptTextParser.analyze(
            fromLines: [
                "Shop",
                "Transaction date 08/03/2026 02:30",
                "TOTAL 5.00"
            ],
            now: now,
            calendar: losAngeles,
            prefersDayFirst: true
        )
        let validResult = ReceiptTextParser.analyze(
            fromLines: [
                "Shop",
                "Transaction date 08/03/2026 03:30",
                "TOTAL 5.00"
            ],
            now: now,
            calendar: losAngeles,
            prefersDayFirst: true
        )
        let expectedValidDate = try XCTUnwrap(losAngeles.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 3,
            minute: 30
        )))

        XCTAssertNil(result.draft.occurredAt)
        XCTAssertTrue(result.dateCandidateDetails.isEmpty)
        XCTAssertEqual(result.draft.amount, Decimal(5))
        XCTAssertEqual(validResult.draft.occurredAt, expectedValidDate)
        XCTAssertEqual(validResult.dateCandidateDetails.first?.confidence, .high)
    }

    func testThousandsSeparatorsAreRead() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Furniture Co", "TOTAL 1,299.00"],
            now: try date(2026, 3, 20),
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(1299))
    }

    func testEmptyScanProducesAnEmptyDraft() {
        let draft = ReceiptTextParser.draft(fromLines: ["", "   "])
        XCTAssertTrue(draft.isEmpty)
    }

    func testSingaporeReceiptRejectsTenderedCashChangeCardTailAndIdentifiers() throws {
        let result = ReceiptTextParser.analyze(
            fromLines: [
                "NTUC FAIRPRICE CO-OPERATIVE LTD",
                "Tel: +65 6123 4567",
                "Receipt No: 00881234",
                "2 x Bread @ 3.20       6.40",
                "SUBTOTAL              27.10",
                "GST 9%                 2.44",
                "GRAND TOTAL       S$  29.54",
                "CASH TENDERED          50.00",
                "CHANGE                 20.46",
                "VISA **** 4821",
                "AUTH 912834"
            ],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(result.draft.amount, Decimal(string: "29.54"))
        XCTAssertEqual(result.draft.payee, "NTUC FAIRPRICE CO-OPERATIVE LTD")
        XCTAssertEqual(result.categoryHint, .groceries)
        XCTAssertEqual(result.noteCandidate, "Receipt No: 00881234")
        XCTAssertEqual(result.amountCandidates.first, Decimal(string: "29.54"))
        XCTAssertFalse(result.amountCandidates.contains(Decimal(50)))
        XCTAssertFalse(result.amountCandidates.contains(Decimal(4821)))
    }

    func testMalaysiaReceiptReadsMixedSeparatorsAndMalayPayableLabel() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "KEDAI PERABOT MAJU SDN BHD",
                "Subjumlah       RM 1.200,00",
                "Cukai              RM 99,00",
                "JUMLAH BESAR    RM 1.299,00",
                "Tunai           RM 1.500,00",
                "Baki              RM 201,00"
            ],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "ms_MY")
        )

        XCTAssertEqual(draft.amount, Decimal(1299))
        XCTAssertEqual(draft.payee, "KEDAI PERABOT MAJU SDN BHD")
    }

    func testPaymentScreenshotExtractsMerchantTimestampAmountCategoryAndReference() throws {
        let result = ReceiptTextParser.analyze(
            fromLines: [
                "Payment successful",
                "Paid to GRAB",
                "Trip fare",
                "S$ 18.20",
                "Transaction date 26 Aug 2026, 8:42 PM",
                "Reference: SG26082612345",
                "Available balance S$ 2,418.55"
            ],
            now: try date(2026, 8, 26, hour: 23),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(result.draft.amount, Decimal(string: "18.20"))
        XCTAssertEqual(result.draft.payee, "GRAB")
        XCTAssertEqual(result.draft.occurredAt, try date(2026, 8, 26, hour: 20).addingTimeInterval(42 * 60))
        XCTAssertEqual(result.categoryHint, .transport)
        XCTAssertEqual(result.noteCandidate, "Reference: SG26082612345")
        XCTAssertFalse(result.amountCandidates.contains(Decimal(string: "2418.55")!))
    }

    func testTwoDigitYearAndTwentyFourHourTimeAreParsed() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "Cafe Merdeka",
                "Date: 25/08/26 13:05",
                "AMOUNT PAID RM 16.80"
            ],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_MY")
        )

        XCTAssertEqual(draft.occurredAt, try date(2026, 8, 25, hour: 13).addingTimeInterval(5 * 60))
        XCTAssertEqual(draft.amount, Decimal(string: "16.80"))
    }

    func testExpiryDateDoesNotBeatTransactionDate() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "Pharmacy",
                "Expiry 01/01/2027",
                "Transaction Date 24/08/2026",
                "TOTAL RM 8.90"
            ],
            now: try date(2026, 8, 26),
            calendar: calendar
        )

        XCTAssertEqual(draft.occurredAt, try date(2026, 8, 24, hour: 0))
    }

    func testRejectsTimestampsPercentagesOrderNumbersAndCardTailsAsFallbackAmounts() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "Transaction Detail",
                "Time 12:45:30",
                "GST 9%",
                "Order No 123.45",
                "VISA **** 4821",
                "Phone +65 8123 4567"
            ],
            now: try date(2026, 8, 26),
            calendar: calendar
        )

        XCTAssertNil(draft.amount)
    }

    func testTotalItemCountCannotBeatPayableAmount() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "Mini Mart",
                "TOTAL ITEMS 12",
                "TOTAL",
                "RM 42.80"
            ],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_MY")
        )

        XCTAssertEqual(draft.amount, Decimal(string: "42.80"))
    }

    func testSplitSubtotalLabelDoesNotOutrankLaterUnlabelledPayableAmount() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: [
                "Mini Mart",
                "SUBTOTAL",
                "27.10",
                "PAYABLE LABEL UNREADABLE",
                "29.54"
            ],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(draft.amount, Decimal(string: "29.54"))
    }

    func testTotalSavingsIsNotTreatedAsThePayableAmount() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Rewards Store", "TOTAL SAVINGS S$ 20.00"],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertNil(draft.amount)
    }

    func testTaxAndServiceComponentTotalsAreNotTreatedAsPayable() throws {
        let nonPayableLines = [
            "TOTAL GST S$ 2.44",
            "TOTAL TAX S$ 2.44",
            "JUMLAH CUKAI RM 6.00",
            "TOTAL SERVICE CHARGE S$ 5.00"
        ]

        for line in nonPayableLines {
            let draft = ReceiptTextParser.draft(
                fromLines: ["Example Merchant", line],
                now: try date(2026, 8, 26),
                calendar: calendar,
                locale: Locale(identifier: "en_SG")
            )
            XCTAssertNil(draft.amount, line)
        }
    }

    func testExplicitlyTaxInclusiveTotalRemainsPayable() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Example Merchant", "TOTAL (incl. GST) S$ 29.54"],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(draft.amount, Decimal(string: "29.54"))
    }

    func testRepairsConservativeOCRConfusionsInsideMonetaryToken() throws {
        let draft = ReceiptTextParser.draft(
            fromLines: ["Coffee Lab", "TOTAL S$ I2.5O"],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(draft.amount, Decimal(string: "12.50"))
    }

    func testCategoryHintMapsOntoUserOwnedCategoryWithoutInventingAnID() throws {
        let groceries = LedgerAccount(name: "Groceries", kind: .expense)
        let transport = LedgerAccount(name: "Transport", kind: .expense)
        let draft = ReceiptTextParser.draft(
            fromLines: ["FAIRPRICE FINEST", "TOTAL S$ 28.40"],
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG"),
            accounts: [transport, groceries]
        )

        XCTAssertEqual(draft.categoryID, groceries.id)
    }

    func testCandidateRankingIsDeterministicAndBestFirst() throws {
        let lines = [
            "Cafe Nero",
            "Latte 7.50",
            "Subtotal 7.50",
            "TOTAL S$ 8.18",
            "NETS 8.18"
        ]
        let first = ReceiptTextParser.analyze(
            fromLines: lines,
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let second = ReceiptTextParser.analyze(
            fromLines: lines,
            now: try date(2026, 8, 26),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.amountCandidates.first, Decimal(string: "8.18"))
        XCTAssertEqual(first.merchantCandidates.first, "Cafe Nero")
    }

    func testCandidateDetailsPreserveScoresConfidenceAndRuleEvidence() throws {
        let result = ReceiptTextParser.analyze(
            fromLines: [
                "Payment successful",
                "Paid to Green Garden Restaurant",
                "Coffee meal",
                "Amount paid S$ 18.20",
                "Transaction date 26 Aug 2026, 8:42 PM"
            ],
            now: try date(2026, 8, 26, hour: 23),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        let amount = try XCTUnwrap(result.amountCandidateDetails.first)
        XCTAssertEqual(amount.value, Decimal(string: "18.20"))
        XCTAssertGreaterThan(amount.score, 0)
        XCTAssertEqual(amount.confidence, CaptureConfidence.high)
        XCTAssertTrue(amount.evidence.contains(.payableAmountLabel))
        XCTAssertTrue(amount.evidence.contains(.currencyMarker))
        XCTAssertTrue(amount.evidence.contains(.fractionalAmount))

        let merchant = try XCTUnwrap(result.merchantCandidateDetails.first)
        XCTAssertEqual(merchant.value, "Green Garden Restaurant")
        XCTAssertEqual(merchant.confidence, .high)
        XCTAssertTrue(merchant.evidence.contains(.explicitMerchantLabel))
        XCTAssertTrue(merchant.evidence.contains(.businessNameMarker))

        let parsedDate = try XCTUnwrap(result.dateCandidateDetails.first)
        XCTAssertEqual(parsedDate.confidence, .high)
        XCTAssertTrue(parsedDate.evidence.contains(.transactionDateLabel))
        XCTAssertTrue(parsedDate.evidence.contains(.timeComponent))

        let category = try XCTUnwrap(result.categoryCandidateDetails.first)
        XCTAssertEqual(category.value, .food)
        XCTAssertEqual(category.score, 3)
        XCTAssertEqual(category.confidence, .high)
        XCTAssertTrue(category.evidence.contains(.categoryKeywordMatch))
        XCTAssertTrue(category.evidence.contains(.multipleCategoryKeywordMatches))
        XCTAssertEqual(result.overallConfidence, .high)

        XCTAssertEqual(result.amountCandidateDetails.map(\.value), result.amountCandidates)
        XCTAssertEqual(result.merchantCandidateDetails.map(\.value), result.merchantCandidates)
        XCTAssertEqual(result.dateCandidateDetails.map(\.value), result.dateCandidates)
    }

    func testWeakParserSignalsRemainExplicitlyLowConfidence() throws {
        let result = ReceiptTextParser.analyze(
            fromLines: [
                "Corner Store",
                "Taxi",
                "26/08/2026",
                "12.50"
            ],
            now: try date(2026, 8, 26, hour: 23),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        let amount = try XCTUnwrap(result.amountCandidateDetails.first)
        XCTAssertEqual(amount.confidence, .low)
        XCTAssertTrue(amount.evidence.contains(.unlabelledAmount))

        let merchant = try XCTUnwrap(result.merchantCandidateDetails.first)
        XCTAssertEqual(merchant.value, "Corner Store")
        XCTAssertEqual(merchant.confidence, .low)

        let parsedDate = try XCTUnwrap(result.dateCandidateDetails.first)
        XCTAssertEqual(parsedDate.confidence, .low)
        XCTAssertEqual(parsedDate.evidence, [.plausibleDate])

        let category = try XCTUnwrap(result.categoryCandidateDetails.first)
        XCTAssertEqual(category.value, .transport)
        XCTAssertEqual(category.score, 1)
        XCTAssertEqual(category.confidence, .low)
        XCTAssertEqual(result.overallConfidence, .low)
    }

    func testOCRConfidenceConservativelyCapsParserConfidenceWithoutChangingValues() throws {
        let lines = [
            "Payment successful",
            "Paid to Green Garden Restaurant",
            "Coffee meal",
            "Amount paid S$ 18.20",
            "Transaction date 26 Aug 2026, 8:42 PM"
        ]
        let baseline = ReceiptTextParser.analyze(
            fromLines: lines,
            now: try date(2026, 8, 26, hour: 23),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let lowOCR = ReceiptTextParser.analyze(
            fromLines: lines,
            now: try date(2026, 8, 26, hour: 23),
            calendar: calendar,
            locale: Locale(identifier: "en_SG"),
            ocrConfidence: 0.42
        )
        let moderateOCR = ReceiptTextParser.analyze(
            fromLines: lines,
            now: try date(2026, 8, 26, hour: 23),
            calendar: calendar,
            locale: Locale(identifier: "en_SG"),
            ocrConfidence: 0.65
        )
        let strongOCR = ReceiptTextParser.analyze(
            fromLines: lines,
            now: try date(2026, 8, 26, hour: 23),
            calendar: calendar,
            locale: Locale(identifier: "en_SG"),
            ocrConfidence: 0.90
        )

        XCTAssertEqual(lowOCR.ocrConfidence, 0.42)
        XCTAssertEqual(lowOCR.amountCandidates, baseline.amountCandidates)
        XCTAssertEqual(lowOCR.merchantCandidates, baseline.merchantCandidates)
        XCTAssertEqual(lowOCR.dateCandidates, baseline.dateCandidates)
        XCTAssertEqual(
            lowOCR.categoryCandidateDetails.map(\.value),
            baseline.categoryCandidateDetails.map(\.value)
        )
        XCTAssertEqual(
            lowOCR.amountCandidateDetails.map(\.score),
            baseline.amountCandidateDetails.map(\.score)
        )
        XCTAssertEqual(lowOCR.amountCandidateDetails.first?.confidence, .low)
        XCTAssertEqual(lowOCR.merchantCandidateDetails.first?.confidence, .low)
        XCTAssertEqual(lowOCR.dateCandidateDetails.first?.confidence, .low)
        XCTAssertEqual(lowOCR.categoryCandidateDetails.first?.confidence, .low)
        XCTAssertEqual(lowOCR.overallConfidence, .low)
        XCTAssertTrue(
            try XCTUnwrap(lowOCR.amountCandidateDetails.first)
                .evidence.contains(.lowOCRConfidence)
        )

        XCTAssertEqual(moderateOCR.amountCandidateDetails.first?.confidence, .medium)
        XCTAssertEqual(moderateOCR.overallConfidence, .medium)
        XCTAssertTrue(
            try XCTUnwrap(moderateOCR.amountCandidateDetails.first)
                .evidence.contains(.moderateOCRConfidence)
        )

        XCTAssertEqual(strongOCR.amountCandidateDetails.first?.confidence, .high)
        XCTAssertEqual(strongOCR.overallConfidence, .high)
        XCTAssertTrue(
            try XCTUnwrap(strongOCR.amountCandidateDetails.first)
                .evidence.contains(.strongOCRConfidence)
        )
    }

    func testLegacyResultInitializerBuildsReviewableCompatibilityDetails() throws {
        let amount = Decimal(string: "9.80")!
        let parsedDate = try date(2026, 8, 26, hour: 0)
        let result = ReceiptParseResult(
            draft: TransactionDraft(amount: amount, source: .receipt),
            amountCandidates: [amount],
            merchantCandidates: ["Example Merchant"],
            dateCandidates: [parsedDate],
            categoryHint: .shopping,
            noteCandidate: nil
        )

        XCTAssertEqual(result.amountCandidateDetails.first?.value, amount)
        XCTAssertEqual(result.merchantCandidateDetails.first?.value, "Example Merchant")
        XCTAssertEqual(result.dateCandidateDetails.first?.value, parsedDate)
        XCTAssertEqual(result.categoryCandidateDetails.first?.value, .shopping)
        XCTAssertEqual(result.amountCandidateDetails.first?.confidence, .low)
        XCTAssertEqual(
            result.amountCandidateDetails.first?.evidence,
            [.unscoredCompatibilityValue]
        )
        XCTAssertNil(result.ocrConfidence)
        XCTAssertNil(result.overallConfidence)
    }
}
