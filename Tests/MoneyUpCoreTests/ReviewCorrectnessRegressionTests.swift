import Foundation
@testable import MoneyUpCore
import XCTest

final class ReviewCorrectnessRegressionTests: XCTestCase {
    func testBackdatedAllowanceCannotConsumeAlreadyUsedRollover() throws {
        let usd = try CurrencyCode("USD")
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let plan = try AllowancePlan(name: "Meals", amount: Money(10, currency: usd),
            cadence: .daily, startsAt: start, timeZoneIdentifier: "UTC", rolloverRule: .full)
        let dayTwo = try plan.addingUsage(AllowanceUsage(amount: Money(20, currency: usd),
            occurredAt: start.addingTimeInterval(86_460), policyRevisionID: plan.policyRevisions[0].id))
        XCTAssertThrowsError(try dayTwo.addingUsage(AllowanceUsage(amount: Money(10, currency: usd),
            occurredAt: start.addingTimeInterval(60))))
        XCTAssertEqual(try JSONDecoder().decode(AllowancePlan.self, from: JSONEncoder().encode(dayTwo)), dayTwo)
    }

    func testCSVFixedDatesStayGregorianAcrossRegionalCalendars() throws {
        for identifier in ["th_TH", "ar_SA", "fa_IR", "en_US", "zh_CN"] {
            let preview = try TransactionCSVImporter.parse("Date,Type,Amount\n2024-01-15,Expense,12",
                locale: Locale(identifier: identifier), timeZone: TimeZone(secondsFromGMT: 0)!)
            XCTAssertTrue(preview.issues.isEmpty, identifier)
            let row = try XCTUnwrap(preview.rows.first, identifier)
            let calendar = Calendar(identifier: .gregorian)
            XCTAssertEqual(calendar.component(.year, from: row.occurredAt), 2024, identifier)
        }
    }

    func testReceiptRespectsThreeDecimalCurrencyEvidence() throws {
        for code in ["BHD", "KWD", "OMR", "JOD", "TND"] {
            for token in ["0.750", "1.250", "0,750"] {
                let result = ReceiptTextParser.analyze(fromLines: ["Currency: \(code)", "Total \(token)"],
                    locale: Locale(identifier: "en_US"))
                XCTAssertEqual(result.draft.amount, Decimal(string: token.replacingOccurrences(of: ",", with: ".")), "\(code) \(token)")
            }
        }
        let grouped = ReceiptTextParser.analyze(fromLines: ["Total USD 1,250"], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(grouped.draft.amount, 1250)
    }
}

extension ReviewCorrectnessRegressionTests {
    func testInverseRateHalfEvenBoundaryCanBeFrozen() throws {
        let usd = try CurrencyCode("USD"), bhd = try CurrencyCode("BHD")
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let origin = TransactionOriginContext.capture(for: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let rate = try DatedExchangeRate(id: UUID(), baseCurrency: usd, quoteCurrency: bhd, rate: 3,
            effectiveContext: origin, createdAt: now)
        let conversion = try XCTUnwrap(HistoricalExchangeRateLookup.conversion(
            of: Money(Decimal(string: "2.445")!, currency: bhd), to: usd, on: origin, rates: [rate]))
        XCTAssertEqual(conversion.converted.amount, Decimal(string: "0.82"))
        let evidence = try NetWorthConversionEvidence(source: conversion.source,
            appliedRate: conversion.appliedRate, rateID: conversion.rateID,
            effectiveDayKey: conversion.effectiveDayKey, usedInverseRate: true,
            converted: conversion.converted, quotedRate: conversion.quotedRate)
        XCTAssertEqual(try JSONDecoder().decode(NetWorthConversionEvidence.self,
            from: JSONEncoder().encode(evidence)), evidence)
    }

    func testAttributionUsesFrozenOffsetWhenZoneRulesChange() throws {
        let usd = try CurrencyCode("USD")
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let entry = try TransactionFactory.expense(amount: Money(1, currency: usd),
            paidFrom: UUID(), category: UUID(), occurredAt: now)
        let attribution = try BudgetEntryAttribution(id: entry.id, occurredAt: now, originTimeZoneIdentifier: "UTC", postings: entry.postings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attribution)) as? [String: Any])
        // Simulate a named zone whose current rules differ from frozen UTC evidence.
        json["originTimeZoneIdentifier"] = "Asia/Singapore"
        let restored = try JSONDecoder().decode(BudgetEntryAttribution.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.originDayKey, attribution.originDayKey)
        XCTAssertEqual(restored.originUTCOffsetSeconds, 0)
        json["originDayKey"] = "2026-01-03"
        XCTAssertThrowsError(try JSONDecoder().decode(BudgetEntryAttribution.self,
            from: JSONSerialization.data(withJSONObject: json)))
    }
}


extension ReviewCorrectnessRegressionTests {
    func testGroupedThreeDecimalReceiptsKeepWholeAndFractionalParts() {
        for token in ["1 234.750", "1,234.750", "1.234,750", "1’234.750"] {
            let result = ReceiptTextParser.analyze(fromLines: ["Total KWD \(token)"],
                locale: Locale(identifier: "en_US"))
            XCTAssertEqual(result.draft.amount, Decimal(string: "1234.750"), token)
        }
    }

    func testFrozenConversionRejectsForgedEvidenceAndReadsLegacySnapshot() throws {
        let usd = try CurrencyCode("USD"), bhd = try CurrencyCode("BHD")
        for amount in ["2.445", "-2.445", "2.415", "-2.415"] {
            let source = try Money(Decimal(string: amount)!, currency: bhd)
            let converted = try Money(CheckedDecimal.divideForCurrencyRounding(source.amount, 3, currency: usd), currency: usd)
            let evidence = try NetWorthConversionEvidence(source: source,
                appliedRate: CheckedDecimal.ratio(1, 3), rateID: UUID(),
                effectiveDayKey: 20260101, usedInverseRate: true, converted: converted, quotedRate: 3)
            XCTAssertEqual(try JSONDecoder().decode(NetWorthConversionEvidence.self,
                from: JSONEncoder().encode(evidence)), evidence)
            XCTAssertThrowsError(try NetWorthConversionEvidence(source: source,
                appliedRate: evidence.appliedRate, rateID: evidence.rateID,
                effectiveDayKey: 20260101, usedInverseRate: true, converted: converted, quotedRate: 4))
        }
        let legacy = try NetWorthConversionEvidence(source: Money(1, currency: bhd),
            appliedRate: 2, rateID: UUID(), effectiveDayKey: 20260101,
            usedInverseRate: false, converted: Money(2, currency: usd))
        XCTAssertEqual(try JSONDecoder().decode(NetWorthConversionEvidence.self,
            from: JSONEncoder().encode(legacy)), legacy)
    }
}


extension ReviewCorrectnessRegressionTests {
    func testUnmarkedThreeDigitSeparatorsCannotSilentlyPrefillAnAssumedCurrency() {
        let zero = ReceiptTextParser.analyze(fromLines: ["Total 0.750"], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(zero.draft.amount, Decimal(string: "0.750"))
        for token in ["1.250", "1,250"] {
            let ambiguous = ReceiptTextParser.analyze(fromLines: ["Total \(token)"], locale: Locale(identifier: "en_US"))
            XCTAssertTrue(ambiguous.requiresExplicitReview, token)
        }
        let dinars = ReceiptTextParser.analyze(fromLines: ["Total KWD 1,250"], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(dinars.draft.amount, 1250)
        XCTAssertTrue(dinars.requiresExplicitReview, "A single grouping/decimal separator is ambiguous for three-decimal money")
        let decimalDinars = ReceiptTextParser.analyze(fromLines: ["Total KWD 1.250"], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(decimalDinars.draft.amount, Decimal(string: "1.250"))
        XCTAssertTrue(decimalDinars.requiresExplicitReview)
        let dollars = ReceiptTextParser.analyze(fromLines: ["Total USD 1,250"], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(dollars.draft.amount, 1250)
        XCTAssertFalse(dollars.requiresExplicitReview)
    }
}
