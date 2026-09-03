import Foundation
@testable import MoneyUpCore
import Testing

struct LedgerPortabilityTests {
    private let sgd = try! CurrencyCode("SGD")
    private let myr = try! CurrencyCode("MYR")

    @Test
    func smartSplitAllocationIsExactAndDeterministic() throws {
        let total = try Money(10, currency: sgd)
        let equal = try TransactionSplitCalculator.equalAmounts(total: total, count: 3)
        #expect(equal.map(\.amount) == [3.34, 3.33, 3.33])

        let percentages = try TransactionSplitCalculator.percentageAmounts(
            total: total,
            percentages: [60, 40]
        )
        #expect(percentages.map(\.amount) == [6, 4])

        let rebalanced = try TransactionSplitCalculator.rebalancedAmounts(
            total: total,
            current: [try Money(7, currency: sgd), nil, nil],
            locked: [true, false, false]
        )
        #expect(rebalanced.map(\.amount) == [7, 1.5, 1.5])
    }

    @Test
    func splitExpenseRequiresExactPerCurrencyBalance() throws {
        let food = UUID()
        let transport = UUID()
        let wallet = UUID()
        let total = try Money(12.50, currency: sgd)
        let lines = [
            TransactionSplitLine(
                categoryAccountID: food,
                amount: try Money(8.25, currency: sgd),
                memo: "meal"
            ),
            TransactionSplitLine(
                categoryAccountID: transport,
                amount: try Money(4.25, currency: sgd)
            )
        ]

        let entry = try TransactionFactory.splitExpense(
            amount: total,
            paidFrom: wallet,
            splits: lines
        )

        #expect(entry.postings.count == 3)
        #expect(entry.balanceByCurrency[sgd] == .zero)
        #expect(entry.postings.first?.memo == "meal")
        #expect(try TransactionSplitCalculator.remainder(total: total, lines: lines).amount == .zero)
    }

    @Test
    func splitRejectsRoundingResidualInsteadOfAutoAdjusting() throws {
        let total = try Money(10, currency: sgd)
        let lines = [
            TransactionSplitLine(categoryAccountID: UUID(), amount: try Money(3.33, currency: sgd)),
            TransactionSplitLine(categoryAccountID: UUID(), amount: try Money(6.66, currency: sgd))
        ]

        #expect(throws: TransactionSplitError.totalMismatch(expected: 10, actual: 9.99)) {
            try TransactionSplitCalculator.validate(total: total, lines: lines)
        }
    }

    @Test
    func splitRejectsOverflowingLegacyLineTotal() throws {
        let huge = try #require(
            Decimal(
                string: "9e127",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let total = try Money(huge, currency: sgd)
        let lines = [
            TransactionSplitLine(
                categoryAccountID: UUID(),
                amount: try Money(huge, currency: sgd)
            ),
            TransactionSplitLine(
                categoryAccountID: UUID(),
                amount: try Money(huge, currency: sgd)
            )
        ]

        #expect(throws: DecimalCalculationError.overflow) {
            try TransactionSplitCalculator.validate(total: total, lines: lines)
        }
    }

    @Test
    func historicalRateUsesLatestApplicableDayAndSupportsInverse() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let calendar = Calendar(identifier: .gregorian)
        let older = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: 3.40,
            effectiveAt: date("2026-08-01"),
            calendar: calendar,
            timeZone: utc
        )
        let future = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: 3.50,
            effectiveAt: date("2026-09-01"),
            calendar: calendar,
            timeZone: utc
        )
        let origin = TransactionOriginContext.capture(
            for: date("2026-08-26"),
            calendar: calendar,
            timeZone: utc
        )

        let direct = try HistoricalExchangeRateLookup.conversion(
            of: Money(10, currency: sgd),
            to: myr,
            on: origin,
            rates: [future, older]
        )
        let inverse = try HistoricalExchangeRateLookup.conversion(
            of: Money(34, currency: myr),
            to: sgd,
            on: origin,
            rates: [older]
        )

        #expect(direct?.converted.amount == 34)
        #expect(direct?.rateID == older.id)
        #expect(direct?.isEstimated == true)
        #expect(inverse?.converted.amount == 10)
        #expect(inverse?.usedInverseRate == true)
    }

    @Test
    func repeatingInverseRateRoundsOnceAtDestinationScale() throws {
        let rate = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: Decimal(string: "3.4")!,
            effectiveAt: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let conversion = try HistoricalExchangeRateLookup.conversion(
            of: Money(1, currency: myr),
            to: sgd,
            on: .inferredUTC(for: Date(timeIntervalSince1970: 1)),
            rates: [rate]
        )

        #expect(conversion?.converted.amount == Decimal(string: "0.29"))
        #expect(conversion?.usedInverseRate == true)
    }

    @Test
    func extremeDirectAndInverseConversionsFailExplicitly() throws {
        let day = Date(timeIntervalSince1970: 0)
        let origin = TransactionOriginContext.inferredUTC(for: day)
        let high = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: Decimal(string: "1e20", locale: Locale(identifier: "en_US_POSIX"))!,
            effectiveAt: day,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let low = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: Decimal(string: "1e-20", locale: Locale(identifier: "en_US_POSIX"))!,
            effectiveAt: day,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let large = Decimal(string: "1e14", locale: Locale(identifier: "en_US_POSIX"))!

        #expect(throws: ExchangeRateError.conversionOutOfRange) {
            try HistoricalExchangeRateLookup.conversion(
                of: Money(large, currency: sgd),
                to: myr,
                on: origin,
                rates: [high]
            )
        }
        #expect(throws: ExchangeRateError.conversionOutOfRange) {
            try HistoricalExchangeRateLookup.conversion(
                of: Money(large, currency: myr),
                to: sgd,
                on: origin,
                rates: [low]
            )
        }
    }

    @Test
    func nonzeroConversionThatRoundsToZeroFailsExplicitly() throws {
        let day = Date(timeIntervalSince1970: 0)
        let rate = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: Decimal(string: "0.001")!,
            effectiveAt: day,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(throws: ExchangeRateError.conversionUnderflow) {
            try HistoricalExchangeRateLookup.conversion(
                of: Money(Decimal(string: "0.01")!, currency: sgd),
                to: myr,
                on: .inferredUTC(for: day),
                rates: [rate]
            )
        }
    }

    @Test
    func noHistoricalRateReturnsUnconvertedMode() throws {
        let origin = TransactionOriginContext.inferredUTC(for: Date())
        let conversion = try HistoricalExchangeRateLookup.conversion(
            of: Money(1, currency: sgd),
            to: myr,
            on: origin,
            rates: []
        )
        #expect(conversion == nil)
    }

    @Test
    func inverseHistoricalRateRoundsOnceInDestinationCurrency() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let calendar = Calendar(identifier: .gregorian)
        let rate = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: 3,
            effectiveAt: date("2026-08-01"),
            calendar: calendar,
            timeZone: utc
        )
        let origin = TransactionOriginContext.capture(
            for: date("2026-08-26"),
            calendar: calendar,
            timeZone: utc
        )

        let conversion = try HistoricalExchangeRateLookup.conversion(
            of: Money(1, currency: myr),
            to: sgd,
            on: origin,
            rates: [rate]
        )

        #expect(conversion?.converted.amount == Decimal(string: "0.33"))
        #expect(conversion?.appliedRate ?? 0 > Decimal(string: "0.333")!)
        #expect(conversion?.appliedRate ?? 0 < Decimal(string: "0.334")!)
    }

    @Test
    func legacyJournalDecodeGetsDeterministicInferredOrigin() throws {
        let entry = try TransactionFactory.expense(
            amount: Money(5, currency: sgd),
            paidFrom: UUID(),
            category: UUID(),
            occurredAt: Date(timeIntervalSince1970: 0)
        )
        let encoded = try JSONEncoder().encode(entry)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "originContext")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(JournalEntry.self, from: legacy)

        #expect(decoded.originContext.wasInferred)
        #expect(decoded.originContext.timeZoneIdentifier == "UTC")
        #expect(decoded.originContext.dayKey == 19700101)
    }

    @Test
    func capturedOriginDayDoesNotMoveWhenReportingTimeZoneChanges() throws {
        let occurredAt = ISO8601DateFormatter().date(from: "2026-08-26T16:30:00Z")!
        let singapore = TimeZone(identifier: "Asia/Singapore")!
        let origin = TransactionOriginContext.capture(
            for: occurredAt,
            timeZone: singapore
        )
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let attributed = try #require(origin.attributedDate(in: utcCalendar))
        let components = utcCalendar.dateComponents([.year, .month, .day], from: attributed)

        #expect(origin.dayKey == 20260827)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 27)
    }

    @Test
    func originContextRejectsImpossibleCivilAndZoneFieldsOnDecode() throws {
        let valid = TransactionOriginContext.capture(
            for: date("2026-08-26"),
            timeZone: TimeZone(identifier: "Asia/Singapore")!
        )
        let encoded = try JSONEncoder().encode(valid)
        let corruptions: [(String, Any)] = [
            ("calendarIdentifier", "buddhist"),
            ("timeZoneIdentifier", "Not/A_Real_Zone"),
            ("utcOffsetSeconds", 100_000),
            ("dayKey", 20_260_230)
        ]

        for (key, value) in corruptions {
            var object = try #require(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object[key] = value
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    TransactionOriginContext.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            }
        }
        #expect(throws: TransactionOriginContextError.invalidUTCOffset) {
            try TransactionOriginContext(
                calendarIdentifier: "gregorian",
                timeZoneIdentifier: "UTC",
                utcOffsetSeconds: 15 * 3_600,
                dayKey: 20260826
            )
        }
    }

    @Test
    func capturedOriginAcceptsAuditedHistoricalOffsetWithoutReattribution() throws {
        let context = try TransactionOriginContext(
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "Asia/Singapore",
            utcOffsetSeconds: 7 * 3_600,
            dayKey: 19811231
        )

        #expect(context.dayKey == 19811231)
        #expect(context.utcOffsetSeconds == 7 * 3_600)
        // Validation is against the persisted offset, not whatever historical
        // rule the device's current tzdb happens to contain.
        try context.validate(eventDate: date("1981-12-31"))
        #expect(throws: TransactionOriginContextError.invalidTimeZone) {
            try TransactionOriginContext(
                calendarIdentifier: "gregorian",
                timeZoneIdentifier: "Asia/Singapore",
                utcOffsetSeconds: 0,
                dayKey: 20260826,
                wasInferred: true
            )
        }
    }

    @Test
    func corruptOriginQuarantinesJournalAndRateDecodeBoundaries() throws {
        let entry = try TransactionFactory.expense(
            amount: Money(5, currency: sgd),
            paidFrom: UUID(),
            category: UUID(),
            occurredAt: date("2026-08-26")
        )
        var entryObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
                as? [String: Any]
        )
        var entryOrigin = try #require(
            entryObject["originContext"] as? [String: Any]
        )
        entryOrigin["dayKey"] = 20_260_230
        entryObject["originContext"] = entryOrigin
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                JournalEntry.self,
                from: JSONSerialization.data(withJSONObject: entryObject)
            )
        }

        var mismatchedEntryObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
                as? [String: Any]
        )
        var mismatchedEntryOrigin = try #require(
            mismatchedEntryObject["originContext"] as? [String: Any]
        )
        mismatchedEntryOrigin["dayKey"] = 20260827
        mismatchedEntryObject["originContext"] = mismatchedEntryOrigin
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                JournalEntry.self,
                from: JSONSerialization.data(withJSONObject: mismatchedEntryObject)
            )
        }

        let rate = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: myr,
            rate: 3.4,
            effectiveAt: date("2026-08-26"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        var rateObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rate))
                as? [String: Any]
        )
        var rateOrigin = try #require(
            rateObject["effectiveContext"] as? [String: Any]
        )
        rateOrigin["timeZoneIdentifier"] = "Not/A_Real_Zone"
        rateObject["effectiveContext"] = rateOrigin
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                DatedExchangeRate.self,
                from: JSONSerialization.data(withJSONObject: rateObject)
            )
        }

        var mismatchedRateObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rate))
                as? [String: Any]
        )
        var mismatchedOrigin = try #require(
            mismatchedRateObject["effectiveContext"] as? [String: Any]
        )
        mismatchedOrigin["dayKey"] = 20260827
        mismatchedRateObject["effectiveContext"] = mismatchedOrigin
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                DatedExchangeRate.self,
                from: JSONSerialization.data(withJSONObject: mismatchedRateObject)
            )
        }

        let otherDay = date("2026-08-27")
        #expect(throws: ExchangeRateError.originContextMismatch) {
            try DatedExchangeRate(
                id: UUID(),
                baseCurrency: sgd,
                quoteCurrency: myr,
                rate: 3.4,
                effectiveContext: rate.effectiveContext,
                createdAt: Date(),
                effectiveAt: otherDay
            )
        }
        #expect(throws: ExchangeRateError.invalidEffectiveDate) {
            try DatedExchangeRate(
                baseCurrency: sgd,
                quoteCurrency: myr,
                rate: 3.4,
                effectiveAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        }
    }

    @Test
    func xlsxUsesNativeNumericAmountsAndNeverFormulaCellsForUserText() throws {
        let wallet = LedgerAccount(name: "=1+1\u{0001}", kind: .asset, currency: sgd)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let entry = try TransactionFactory.expense(
            amount: Money(12.34, currency: sgd),
            paidFrom: wallet.id,
            category: food.id,
            payee: "=HYPERLINK(\"https://invalid\")"
        )

        let data = LedgerXLSXExporter.export(entries: [entry], accounts: [wallet, food])

        #expect(data.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        #expect(data.range(of: Data("<v>12.34</v>".utf8)) != nil)
        #expect(data.range(of: Data("=HYPERLINK".utf8)) != nil)
        #expect(data.range(of: Data("<f>".utf8)) == nil)
        #expect(data.range(of: Data("=1+1\u{0001}".utf8)) == nil)
        #expect(data.range(of: Data("=1+1".utf8)) != nil)
        #expect(data.range(of: Data(entry.id.uuidString.lowercased().utf8)) != nil)
        #expect(data.range(of: Data("Transactions".utf8)) != nil)
    }

    @Test
    func xlsxDuplicateAccountIdentityUsesFirstValueWithoutTrapping() throws {
        let wallet = LedgerAccount(name: "Primary Wallet", kind: .asset, currency: sgd)
        let duplicate = LedgerAccount(
            id: wallet.id,
            name: "Conflicting Duplicate",
            kind: .liability,
            currency: sgd
        )
        let food = LedgerAccount(name: "Food", kind: .expense)
        let entry = try TransactionFactory.expense(
            amount: Money(12.34, currency: sgd),
            paidFrom: wallet.id,
            category: food.id
        )

        let data = LedgerXLSXExporter.export(
            entries: [entry],
            accounts: [wallet, duplicate, food]
        )

        #expect(data.range(of: Data("Primary Wallet".utf8)) != nil)
        #expect(data.range(of: Data("Conflicting Duplicate".utf8)) == nil)
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
