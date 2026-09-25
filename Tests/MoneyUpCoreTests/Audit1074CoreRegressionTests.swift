import Foundation
@testable import MoneyUpCore
import XCTest

/// Core regressions from the audit of 0.7.2 (1074.1); see
/// docs/AUDIT_2026-09-25.md. Each test fails on the audited build.
final class Audit1074CoreRegressionTests: XCTestCase {
    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    private func gym(
        from anchor: Date,
        frequency: RecurrenceFrequency = .monthly,
        zone: String? = "America/New_York"
    ) throws -> ScheduledTransaction {
        try ScheduledTransaction(
            kind: .expense,
            name: "Gym",
            amount: try Money(30, currency: CurrencyCode("USD")),
            accountID: UUID(),
            categoryAccountID: UUID(),
            nextOccurrence: anchor,
            frequency: frequency,
            recurrenceTimeZoneIdentifier: zone
        )
    }

    private func roundTrip(_ schedule: ScheduledTransaction) throws -> ScheduledTransaction {
        try JSONDecoder().decode(ScheduledTransaction.self, from: JSONEncoder().encode(schedule))
    }

    private func decode(_ json: [String: Any]) throws -> ScheduledTransaction {
        try JSONDecoder().decode(ScheduledTransaction.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func json(_ schedule: ScheduledTransaction) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule)) as? [String: Any])
    }

    // MARK: - Schedules survive a reporting-zone change (T1)

    func testScheduleResolvedAfterAReportingZoneChangeStaysDecodableInItsOwnZone() throws {
        let newYork = try calendar("America/New_York")
        let tokyo = try calendar("Asia/Tokyo")
        let anchor = try date(newYork, 2026, 1, 15, 9)
        var schedule = try gym(from: anchor)
        for resolvingCalendar in [newYork, newYork, tokyo, tokyo] {   // the book moves to Tokyo in March
            try schedule.resolveCurrent(
                occurrenceID: schedule.currentOccurrenceID, as: .skipped, at: anchor, calendar: resolvingCalendar
            )
        }
        XCTAssertEqual(schedule.recurrenceTimeZoneIdentifier, "America/New_York")
        let decoded = try roundTrip(schedule)   // the audited build threw here
        XCTAssertEqual(decoded, schedule)
        let may = newYork.dateComponents([.month, .day, .hour], from: decoded.nextOccurrence)
        XCTAssertEqual([may.month, may.day, may.hour], [5, 15, 9], "still 09:00 in the series' own zone")
        XCTAssertEqual(decoded.resolutions.count, 4)
    }

    func testWeeklyScheduleAcrossADaylightSavingZoneChangeStaysDecodable() throws {
        let newYork = try calendar("America/New_York")
        let utc = try calendar("UTC")
        let anchor = try date(newYork, 2026, 2, 23, 9)          // before US daylight saving begins
        var schedule = try gym(from: anchor, frequency: .weekly)
        for resolvingCalendar in [newYork, utc, utc, utc] {
            try schedule.resolveCurrent(
                occurrenceID: schedule.currentOccurrenceID, as: .skipped, at: anchor, calendar: resolvingCalendar
            )
        }
        XCTAssertNoThrow(try roundTrip(schedule))
        XCTAssertEqual(newYork.component(.hour, from: schedule.nextOccurrence), 9)
    }

    func testRecordWrittenByTheAuditedBuildAfterAZoneChangeDecodesAgain() throws {
        // The audited build re-zoned the series to Tokyo while January–March
        // stayed anchored in New York; March differed by one hour (DST).
        let newYork = try calendar("America/New_York")
        let tokyo = try calendar("Asia/Tokyo")
        var schedule = try gym(from: try date(newYork, 2026, 1, 15, 9))
        for _ in 0..<3 {
            try schedule.resolveCurrent(
                occurrenceID: schedule.currentOccurrenceID, as: .skipped, at: Date(), calendar: newYork
            )
        }
        var record = try json(schedule)
        record["recurrenceTimeZoneIdentifier"] = "Asia/Tokyo"
        record["nextOccurrence"] = try date(tokyo, 2026, 4, 15, 23).timeIntervalSinceReferenceDate
        let recovered = try decode(record)
        XCTAssertEqual(recovered.recurrenceTimeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(recovered.currentOccurrenceIndex, 3)
    }

    func testLegacyScheduleWithoutAZoneAdoptsTheResolvingZoneOnce() throws {
        let tokyo = try calendar("Asia/Tokyo")
        let anchor = try date(tokyo, 2026, 1, 31, 20)
        var schedule = try gym(from: anchor, zone: nil)
        try schedule.resolveCurrent(occurrenceID: schedule.currentOccurrenceID, as: .skipped, at: anchor, calendar: tokyo)
        XCTAssertEqual(schedule.recurrenceTimeZoneIdentifier, "Asia/Tokyo")
        let february = tokyo.dateComponents([.month, .day, .hour], from: schedule.nextOccurrence)
        XCTAssertEqual([february.month, february.day, february.hour], [2, 28, 20], "month-end clamp")
        XCTAssertNoThrow(try roundTrip(schedule))
    }

    func testAnchoredValidationToleratesZoneRuleRevisionsButRejectsMisanchoring() throws {
        let newYork = try calendar("America/New_York")
        var schedule = try gym(from: try date(newYork, 2026, 1, 15, 9))
        try schedule.resolveCurrent(occurrenceID: schedule.currentOccurrenceID, as: .skipped, at: Date(), calendar: newYork)
        let base = try json(schedule)
        let next = try XCTUnwrap(base["nextOccurrence"] as? Double)

        // An OS time-zone data update moves a stored future instant by hours.
        let revisions: [TimeInterval] = [3_600, -3_600, 7_200, ScheduledTransaction.anchoredOccurrenceTolerance]
        for shift in revisions {
            var revised = base
            revised["nextOccurrence"] = next + shift
            XCTAssertNoThrow(try decode(revised), "shift \(shift)")
        }
        // A different day is a misanchored record, as is a tampered resolution.
        let tampers: [TimeInterval] = [ScheduledTransaction.anchoredOccurrenceTolerance + 1, -2 * 86_400, 7 * 86_400]
        for shift in tampers {
            var tampered = base
            tampered["nextOccurrence"] = next + shift
            XCTAssertThrowsError(try decode(tampered), "shift \(shift)")
        }
        var tamperedResolution = base
        var resolutions = try XCTUnwrap(base["resolutions"] as? [[String: Any]])
        let resolved = try XCTUnwrap(resolutions[0]["scheduledFor"] as? Double)
        resolutions[0]["scheduledFor"] = resolved - 3 * 86_400
        tamperedResolution["resolutions"] = resolutions
        XCTAssertThrowsError(try decode(tamperedResolution))
    }

    func testToleranceStaysBelowHalfTheShortestRecurrenceInterval() {
        // Weekly occurrences are the closest together; an index can never be
        // mistaken for its neighbour within the tolerance.
        XCTAssertLessThan(ScheduledTransaction.anchoredOccurrenceTolerance, 7 * 86_400 / 2)
    }

    // MARK: - Midnight daylight-saving days (T5)

    func testPaceCountsCivilDaysWhereDaylightSavingStartsAtMidnight() throws {
        let santiago = try calendar("America/Santiago")
        let noon = try date(santiago, 2026, 9, 6, 12)
        XCTAssertEqual(santiago.component(.hour, from: santiago.startOfDay(for: noon)), 1, "the day starts at 01:00")
        let period = try BudgetPaceCalculator.reportingPeriod(asOf: noon, calendar: santiago)
        XCTAssertEqual(period.remainingDayCount, 25, "the audited build counted 24")

        let clp = try CurrencyCode("CLP")
        let daily = try BudgetPaceCalculator.pace(
            remaining: try Money(250, currency: clp), cadence: .daily, asOf: noon, calendar: santiago
        )
        XCTAssertEqual(daily.available, try Money(10, currency: clp))
        XCTAssertEqual(daily.interval.end, try date(santiago, 2026, 9, 7), "tomorrow starts at midnight, not 01:00")
        let weekly = try BudgetPaceCalculator.pace(
            remaining: try Money(250, currency: clp), cadence: .weekly, asOf: noon, calendar: santiago
        )
        XCTAssertEqual(weekly.available, try Money(70, currency: clp))
        XCTAssertEqual(weekly.interval.end, try date(santiago, 2026, 9, 13))
    }

    func testPaceOnAMonthsLastDayStartingAtOneAMIsOneDayNotAnError() throws {
        let usd = try CurrencyCode("USD")
        for (zone, year, month, day) in [("Asia/Beirut", 2030, 3, 31), ("Africa/Cairo", 2027, 4, 30)] {
            let local = try calendar(zone)
            let noon = try date(local, year, month, day, 12)
            let period = try BudgetPaceCalculator.reportingPeriod(asOf: noon, calendar: local)
            XCTAssertEqual(period.remainingDayCount, 1, zone)
            for cadence in [BudgetPacingCadence.daily, .weekly, .monthly] {
                let pace = try BudgetPaceCalculator.pace(
                    remaining: try Money(42, currency: usd), cadence: cadence, asOf: noon, calendar: local
                )
                XCTAssertEqual(pace.available, try Money(42, currency: usd), "\(zone) \(cadence)")
            }
        }
    }

    func testPaceStillCountsOrdinaryAndFallBackDaysExactly() throws {
        let usd = try CurrencyCode("USD")
        for (zone, year, month, day, expected) in [
            ("America/New_York", 2026, 11, 1, 30),   // a 25-hour day
            ("America/New_York", 2026, 3, 8, 24),    // a 23-hour day at 02:00
            ("Asia/Singapore", 2028, 2, 29, 1),      // leap day, last of the month
            ("Asia/Singapore", 2026, 9, 25, 6)
        ] {
            let local = try calendar(zone)
            let period = try BudgetPaceCalculator.reportingPeriod(asOf: try date(local, year, month, day, 12), calendar: local)
            XCTAssertEqual(period.remainingDayCount, expected, "\(zone) \(year)-\(month)-\(day)")
        }
        let sgt = try calendar("Asia/Singapore")
        let daily = try BudgetPaceCalculator.pace(
            remaining: try Money(-60, currency: usd), cadence: .daily, asOf: try date(sgt, 2026, 9, 25, 12), calendar: sgt
        )
        XCTAssertEqual(daily.available, try Money(-10, currency: usd), "an overspend splits by the same civil days")
    }

    func testWeeklyScheduleAnchoredOnAMidnightDaylightSavingDayStillRecurs() throws {
        let beirut = try calendar("Asia/Beirut")
        let anchor = try date(beirut, 2026, 3, 29, 9)   // daylight saving began at 00:00
        let schedule = try gym(from: anchor, frequency: .weekly, zone: "Asia/Beirut")
        XCTAssertTrue(schedule.occurs(on: anchor, calendar: beirut))
        XCTAssertTrue(schedule.occurs(on: try date(beirut, 2026, 4, 5, 12), calendar: beirut))
        XCTAssertTrue(schedule.occurs(on: try date(beirut, 2026, 4, 12, 0), calendar: beirut))
        XCTAssertFalse(schedule.occurs(on: try date(beirut, 2026, 4, 6, 12), calendar: beirut))
        XCTAssertFalse(schedule.occurs(on: try date(beirut, 2026, 3, 22, 12), calendar: beirut))
    }

    func testCivilDayDistanceCountsDatesNotElapsedTime() throws {
        let beirut = try calendar("Asia/Beirut")
        let shortDay = beirut.startOfDay(for: try date(beirut, 2026, 3, 29, 9))
        XCTAssertEqual(FinancialPeriodBoundary.civilDayDistance(from: shortDay, to: try date(beirut, 2026, 4, 5), calendar: beirut), 7)
        XCTAssertEqual(FinancialPeriodBoundary.civilDayDistance(from: try date(beirut, 2026, 4, 5), to: shortDay, calendar: beirut), -7)
        XCTAssertEqual(FinancialPeriodBoundary.civilDayDistance(from: shortDay, to: shortDay, calendar: beirut), 0)
        let utc = try calendar("UTC")
        XCTAssertEqual(FinancialPeriodBoundary.civilDayDistance(
            from: try date(utc, 2028, 2, 28, 23), to: try date(utc, 2028, 3, 1, 1), calendar: utc
        ), 2)
    }

    // MARK: - Deleting a category that carries rollover (T4)

    func testRecordingWithoutADeletedCategoryForfeitsOnlyItsOpeningCarry() throws {
        let sgd = try CurrencyCode("SGD")
        let singapore = try calendar("Asia/Singapore")
        let august = try date(singapore, 2026, 8, 1)
        let september = try date(singapore, 2026, 9, 1)
        let october = try date(singapore, 2026, 10, 1)
        let travel = BudgetNode(
            id: UUID(), name: "Travel", limit: try Money(200, currency: sgd),
            rolloverRule: .positiveOnly, rolloverStartedAt: august
        )
        let food = BudgetNode(id: UUID(), name: "Food", limit: try Money(500, currency: sgd))
        let timeline = try BudgetConfigurationTimeline(currency: sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: august, nodes: [travel, food]),
            BudgetConfigurationRevision(
                effectiveMonth: september,
                nodes: [travel, food],
                openingCarry: [travel.id: try Money(200, currency: sgd), food.id: try Money(30, currency: sgd)]
            )
        ])

        // Deleting Travel in September threw invalidCarryMapping on the audited build.
        let deleted = try timeline.recording(nodes: [food], effectiveMonth: september)
        XCTAssertEqual(deleted.revision(effectiveAt: september).openingCarryByID, [food.id: try Money(30, currency: sgd)])
        XCTAssertEqual(deleted.revision(effectiveAt: august).nodes.count, 2, "closed months keep their history")

        // A merge carries the source's balance through its mapping instead.
        let merged = try timeline.recording(
            nodes: [food], effectiveMonth: september,
            carryMappings: [BudgetCarryMapping(sourceID: travel.id, targetID: food.id)]
        )
        XCTAssertEqual(merged.revision(effectiveAt: september).openingCarryByID?[travel.id], try Money(200, currency: sgd))

        // A new month records opening carry for surviving categories only.
        let later = try timeline.recording(
            nodes: [food], effectiveMonth: october,
            openingCarry: [travel.id: try Money(400, currency: sgd), food.id: try Money(10, currency: sgd)]
        )
        XCTAssertEqual(later.revision(effectiveAt: october).openingCarryByID, [food.id: try Money(10, currency: sgd)])
        XCTAssertNoThrow(try JSONDecoder().decode(BudgetConfigurationTimeline.self, from: JSONEncoder().encode(later)))
    }

    // MARK: - Safe to spend reserves this month's unposted occurrences (T6)

    private func flexibleCommitments(_ schedules: [ScheduledTransaction], category: UUID, asOf: Date, calendar: Calendar) throws -> (Decimal, Int) {
        let result = try XCTUnwrap(FinanceCalculator.flexibleToday(
            flexibleBudgetRemaining: try Money(1000, currency: CurrencyCode("SGD")),
            schedules: schedules, flexibleCategoryIDs: [category], asOf: asOf, calendar: calendar
        ))
        return (result.flexibleCommitments.amount, result.schedulesNeedingReview)
    }

    private func bill(_ amount: Decimal, _ next: Date, _ frequency: RecurrenceFrequency, category: UUID) throws -> ScheduledTransaction {
        try ScheduledTransaction(
            kind: .expense, name: "Bill", amount: try Money(amount, currency: CurrencyCode("SGD")),
            accountID: UUID(), categoryAccountID: category, nextOccurrence: next,
            frequency: frequency, recurrenceTimeZoneIdentifier: "UTC"
        )
    }

    func testFlexibleTodayReservesEveryUnpostedOccurrenceDatedThisMonthOnly() throws {
        let utc = try calendar("UTC")
        let category = UUID()
        let asOf = try date(utc, 2026, 9, 25, 12)

        // Weekly, unposted since Monday 31 August: 7, 14, 21 (overdue) and 28 September
        // are owed this month; 31 August posts to August. The audited build reserved two.
        let weekly = try bill(50, try date(utc, 2026, 8, 31, 9), .weekly, category: category)
        let (weeklyReserved, weeklyReview) = try flexibleCommitments([weekly], category: category, asOf: asOf, calendar: utc)
        XCTAssertEqual(weeklyReserved, 200)
        XCTAssertEqual(weeklyReview, 1)

        // Monthly, unposted since 5 August: only 5 September is owed this month.
        let monthly = try bill(80, try date(utc, 2026, 8, 5, 9), .monthly, category: category)
        XCTAssertEqual(try flexibleCommitments([monthly], category: category, asOf: asOf, calendar: utc).0, 80)

        // Overdue within the month, and a first occurrence next month.
        let thisMonth = try bill(30, try date(utc, 2026, 9, 3, 9), .monthly, category: category)
        let nextMonth = try bill(30, try date(utc, 2026, 10, 1, 9), .monthly, category: category)
        XCTAssertEqual(try flexibleCommitments([thisMonth, nextMonth], category: category, asOf: asOf, calendar: utc).0, 30)

        // Paused schedules and other categories reserve nothing.
        var paused = weekly
        try paused.pause()
        let elsewhere = try bill(70, try date(utc, 2026, 9, 26, 9), .monthly, category: UUID())
        XCTAssertEqual(try flexibleCommitments([paused, elsewhere], category: category, asOf: asOf, calendar: utc).0, 0)
    }

    // MARK: - Months that begin at 01:00 (T11)

    func testRolloverReplaysThroughAMonthThatDaylightSavingStartsAtOneAM() throws {
        let asuncion = try calendar("America/Asuncion")
        let pyg = try CurrencyCode("PYG")
        let months = try [9, 10, 11].map { month in
            try XCTUnwrap(asuncion.dateInterval(of: .month, for: try date(asuncion, 2023, month, 15, 12))?.start)
        }
        XCTAssertEqual(asuncion.component(.hour, from: months[1]), 1, "October 2023 began at 01:00")
        let id = UUID()
        let food = BudgetNode(
            id: id, name: "Food", limit: try Money(1000, currency: pyg),
            rolloverRule: .positiveOnly, rolloverStartedAt: months[0]
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: pyg, revisions: [BudgetConfigurationRevision(effectiveMonth: months[0], nodes: [food])]
        )
        let spending = try months.map {
            MonthlyBudgetSpending(monthStart: $0, directSpending: [id: try Money(400, currency: pyg)])
        }
        // The audited build stepped to 1 November 01:00, missed November's key, then threw.
        let snapshot = try BudgetRolloverEngine.snapshot(
            timeline: timeline, monthlySpending: spending,
            asOf: try date(asuncion, 2023, 12, 15, 12), calendar: asuncion
        )
        XCTAssertEqual(snapshot.carryIn[id], try Money(1800, currency: pyg), "600 unspent in each of three months")
    }

    func testTrendMonthsStayOnMonthStartsAfterAOneAMMonth() throws {
        let asuncion = try calendar("America/Asuncion")
        let interval = DateInterval(start: try date(asuncion, 2023, 9, 1), end: try date(asuncion, 2024, 1, 1))
        let starts = FinanceCalculator.monthStarts(in: interval, calendar: asuncion)
        XCTAssertEqual(starts.count, 4)
        for start in starts {
            XCTAssertEqual(asuncion.dateInterval(of: .month, for: start)?.start, start)
        }
        XCTAssertEqual(asuncion.component(.hour, from: starts[2]), 0, "November starts at midnight")
    }

    // MARK: - Tiny foreign balances in estimates (M2)

    func testTinyForeignBalanceRoundsToZeroInEstimatesButNeverInPostings() throws {
        let cny = try CurrencyCode("CNY")
        let jpy = try CurrencyCode("JPY")
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let rateDay = try date(try calendar("Asia/Tokyo"), 2026, 9, 1, 12)
        let rate = try DatedExchangeRate(
            baseCurrency: cny, quoteCurrency: jpy, rate: try XCTUnwrap(Decimal(string: "20.5")),
            effectiveAt: rateDay, timeZone: tokyo
        )
        let origin = TransactionOriginContext.capture(for: rateDay.addingTimeInterval(86_400), timeZone: tokyo)
        let crumbs = try Money(try XCTUnwrap(Decimal(string: "0.02")), currency: cny)

        // A posted conversion must never invent a zero amount.
        XCTAssertThrowsError(try HistoricalExchangeRateLookup.conversion(of: crumbs, to: jpy, on: origin, rates: [rate])) {
            XCTAssertEqual($0 as? ExchangeRateError, .conversionUnderflow)
        }
        // An estimate says truthfully that CN¥0.02 is worth ¥0 instead of failing the whole total.
        for source in [crumbs, crumbs.negated] {
            let estimate = try XCTUnwrap(HistoricalExchangeRateLookup.conversion(
                of: source, to: jpy, on: origin, rates: [rate], permitsRoundingToZero: true
            ))
            XCTAssertEqual(estimate.converted.amount, .zero)
            let evidence = try NetWorthConversionEvidence(
                source: source, appliedRate: estimate.appliedRate, rateID: estimate.rateID,
                effectiveDayKey: estimate.effectiveDayKey, usedInverseRate: estimate.usedInverseRate,
                converted: estimate.converted, quotedRate: estimate.quotedRate
            )
            XCTAssertEqual(try JSONDecoder().decode(
                NetWorthConversionEvidence.self, from: JSONEncoder().encode(evidence)
            ), evidence)
        }
        // A non-zero stored value that the rate cannot produce is still rejected.
        let estimate = try XCTUnwrap(HistoricalExchangeRateLookup.conversion(
            of: crumbs, to: jpy, on: origin, rates: [rate], permitsRoundingToZero: true
        ))
        XCTAssertThrowsError(try NetWorthConversionEvidence(
            source: crumbs, appliedRate: estimate.appliedRate, rateID: estimate.rateID,
            effectiveDayKey: estimate.effectiveDayKey, usedInverseRate: false,
            converted: try Money(1, currency: jpy), quotedRate: estimate.quotedRate
        ))
    }

    // MARK: - CSV import never shifts columns silently (P2)

    func testCSVRowWithAnUnquotedCommaIsAnIssueNotAShiftedAmount() throws {
        let csv = """
        Date,Type,Amount,Payee,Note
        2026-01-05,Expense,1,250.00,Landlord,January rent
        2026-01-06,Expense,4.50,Coffee,
        2026-01-07,Expense,3.20,"Acme, Inc.",
        2026-01-08,Expense,7.00,Kopi,,
        """
        let preview = try TransactionCSVImporter.parse(
            csv, locale: Locale(identifier: "en_US_POSIX"), timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )
        XCTAssertEqual(preview.issues.map(\.reason), ["column_count_mismatch"], "the audited build imported rent as 1.00")
        XCTAssertEqual(preview.issues.map(\.line), [2])
        // Quoted commas and an empty trailing field still parse.
        XCTAssertEqual(preview.rows.map(\.amount), ["4.50", "3.20", "7.00"].compactMap { Decimal(string: $0) })
        XCTAssertEqual(preview.rows.map(\.payee), ["Coffee", "Acme, Inc.", "Kopi"])
    }

    // MARK: - Smart Entry keeps an amount followed by punctuation (P3)

    private let smartEntryAccounts = [
        LedgerAccount(name: "Cash", kind: .asset, currency: try? CurrencyCode("SGD")),
        LedgerAccount(name: "Food", kind: .expense)
    ]

    private func interpret(_ text: String) throws -> SmartEntryInterpretation {
        SmartEntryInterpreter.interpret(
            text, accounts: smartEntryAccounts, now: Date(timeIntervalSince1970: 1_790_000_000),
            calendar: try calendar("Asia/Singapore"), locale: Locale(identifier: "en_SG")
        )
    }

    func testAmountFollowedByPunctuationIsKept() throws {
        // The Chinese IME comma normalises to "," — the audited build lost the amount.
        for (phrase, amount) in [("午饭 25，昨天", "25"), ("Lunch 12.50.", "12.50"), ("coffee 4, cash", "4"), ("taxi 18!", "18"), ("书 30。", "30")] {
            let result = try interpret(phrase)
            XCTAssertEqual(result.parsed.draft.amount, Decimal(string: amount), phrase)
            XCTAssertFalse(result.parsed.needsAmountReview, phrase)
            XCTAssertFalse(result.parsed.draft.payee?.contains(amount) ?? false, "\(phrase): amount left in the payee")
        }
        XCTAssertEqual(try interpret("coffee 4, cash").parsed.draft.accountID, smartEntryAccounts[0].id)
    }

    func testTwoLinesEndingInPunctuationStayTwoEntries() throws {
        // The audited build merged these into one 12.50 entry and dropped the coffee.
        XCTAssertEqual(try interpret("coffee 4, cash\nlunch 12.50").shape, .multiple)
        XCTAssertEqual(try interpret("coffee 4\nlunch 12.50").shape, .multiple)
    }

    func testPunctuationNeverTurnsASeparatorIntoAnAmount() throws {
        XCTAssertNil(try interpret("coffee .5").parsed.draft.amount, "a leading separator is not 5")
        XCTAssertEqual(try interpret("rent 1,250.00, bank").parsed.draft.amount, Decimal(string: "1250.00"))
        let malformed = try interpret("parts 88.8.8.")
        XCTAssertNil(malformed.parsed.draft.amount)
        XCTAssertTrue(malformed.parsed.needsAmountReview)
        XCTAssertEqual(TextScanner.amounts(in: "Total 12.50.", locale: Locale(identifier: "en_US")).map(\.value), ["12.50"].compactMap { Decimal(string: $0) })
        XCTAssertEqual(TextScanner.amounts(in: "Paid 12:30, 7.20.", locale: Locale(identifier: "en_US")).map(\.value), ["7.20"].compactMap { Decimal(string: $0) })
    }

    // MARK: - Overpaid loans (M4)

    func testOverpaidLoanSummarisesAsFullyPaidWithACredit() throws {
        let usd = try CurrencyCode("USD")
        let plan = try LoanPlan(
            accountID: UUID(), name: "Car loan",
            originalPrincipal: try Money(100, currency: usd), openedAt: Date(timeIntervalSince1970: 100)
        )
        // Paying 150 by an ordinary transfer left −50; the audited build threw here,
        // so the loan screen showed an arithmetic error and could not be closed.
        let overpaid = try plan.summary(currentPrincipal: try Money(-50, currency: usd))
        XCTAssertEqual(overpaid.remainingPrincipal.amount, -50)
        XCTAssertEqual(overpaid.principalPaid.amount, 100)
        XCTAssertEqual(overpaid.totalPrincipalAdvanced.amount, 100)

        XCTAssertEqual(try plan.summary(currentPrincipal: .zero(currency: usd)).principalPaid.amount, 100)
        XCTAssertEqual(try plan.summary(currentPrincipal: try Money(40, currency: usd)).principalPaid.amount, 60)
        XCTAssertThrowsError(try plan.summary(currentPrincipal: try Money(1, currency: CurrencyCode("EUR"))))
    }
}
