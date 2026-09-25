import Foundation
import MoneyUpCore
@testable import MoneyUp
import XCTest

/// Regressions from the audit of 0.7.2 (1074.1); see docs/AUDIT_2026-09-25.md.
/// Each test pins behaviour the audited build got wrong.
final class Audit1074RegressionTests: XCTestCase {
    private let singapore = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "Asia/Singapore")

    private func sgt(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(singapore.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }

    /// Runs `body` with the App Group language preference set, then restores it.
    private func withLanguage(_ language: AppLanguagePreference, _ body: () throws -> Void) throws {
        let defaults = try XCTUnwrap(AppLanguagePreference.defaults)
        let prior = defaults.string(forKey: AppLanguagePreference.storageKey)
        defer {
            if let prior { defaults.set(prior, forKey: AppLanguagePreference.storageKey) }
            else { defaults.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        defaults.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
        try body()
    }

    /// Travel: the device zone moves while the book stays anchored.
    private func withDeviceTimeZone(_ identifier: String, _ body: () throws -> Void) throws {
        let prior = NSTimeZone.default
        defer { NSTimeZone.default = prior }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: identifier))
        try body()
    }

    private func withAmountsHidden(_ hidden: Bool, _ body: () throws -> Void) rethrows {
        let prior = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        UserDefaults.standard.set(hidden, forKey: MoneyAmountPrivacy.storageKey)
        try body()
    }

    // MARK: - Programmatic dates follow the in-app language

    func testReportingDatesFollowTheInAppLanguageNotTheDeviceLanguage() throws {
        let lunch = try sgt(2026, 9, 18, 11)
        try withLanguage(.simplifiedChinese) {
            let row = lunch.formattedForReporting(.dateTime.month().day().hour().minute(), calendar: singapore)
            XCTAssertTrue(row.contains("9月18日"), row)
            XCTAssertFalse(row.contains("Sep"), row)
        }
        try withLanguage(.english) {
            let row = lunch.formattedForReporting(.dateTime.month().day().hour().minute(), calendar: singapore)
            XCTAssertTrue(row.hasPrefix("Sep 18"), row)
        }
    }

    func testAnExplicitLocaleOverridesTheLanguagePreference() throws {
        try withLanguage(.english) {
            let day = try sgt(2026, 9, 18).formattedForReporting(
                .dateTime.year().month().day(), calendar: singapore, locale: Locale(identifier: "zh-Hans")
            )
            XCTAssertTrue(day.contains("2026") && day.contains("9月18日"), day)
        }
    }

    // MARK: - Reporting-zone days never shift with the device zone

    func testHistoryDayHeaderNamesTheReportingDayWhenTheDeviceIsWestOfIt() throws {
        let groupDay = singapore.startOfDay(for: try sgt(2026, 9, 18, 9))
        try withLanguage(.english) {
            for deviceZone in ["Europe/London", "America/Los_Angeles", "Pacific/Kiritimati"] {
                try withDeviceTimeZone(deviceZone) {
                    let header = groupDay.formattedForReporting(
                        .dateTime.weekday(.wide).month().day().year(), calendar: singapore
                    )
                    XCTAssertTrue(header.contains("Friday") && header.contains("18"), "\(deviceZone): \(header)")
                }
            }
        }
    }

    func testRowsUnderADayHeaderShowOnlyTheirTime() throws {
        let day = singapore.startOfDay(for: try sgt(2026, 9, 18, 9))
        let timeOnly = Date.FormatStyle.dateTime.hour().minute()
        let dated = Date.FormatStyle.dateTime.month().day().hour().minute()
        XCTAssertEqual(TransactionRowDate.format(occurredAt: day, listedDay: day, calendar: singapore), timeOnly)
        XCTAssertEqual(
            TransactionRowDate.format(occurredAt: try sgt(2026, 9, 18, 23, 59), listedDay: day, calendar: singapore),
            timeOnly
        )
        // A travel-attributed entry grouped under another civil day keeps its date.
        XCTAssertEqual(
            TransactionRowDate.format(occurredAt: try sgt(2026, 9, 19, 0, 30), listedDay: day, calendar: singapore),
            dated
        )
        XCTAssertEqual(TransactionRowDate.format(occurredAt: day, listedDay: nil, calendar: singapore), dated)
    }

    func testHistoryDayGroupingMatchesTheOriginalAlgorithmForARandomTravelBook() throws {
        var random = SplitMix64(seed: 0x1074)
        let sgd = try CurrencyCode("SGD")
        let cash = UUID()
        let food = UUID()
        let zones = ["Asia/Singapore", "Europe/London", "America/Los_Angeles", "Pacific/Kiritimati", "Asia/Kolkata"]
            .compactMap(TimeZone.init(identifier:))
        let start = try sgt(2026, 3, 1)
        let entries: [JournalEntry] = try (0..<600).map { _ in
            let occurredAt = start.addingTimeInterval(TimeInterval(random.next() % (400 * 86_400)))
            let zone = zones[Int(random.next() % UInt64(zones.count))]
            return try JournalEntry(
                kind: .expense,
                occurredAt: occurredAt,
                postings: [
                    Posting(accountID: food, money: try Money(5, currency: sgd)),
                    Posting(accountID: cash, money: try Money(-5, currency: sgd))
                ],
                originContext: .capture(for: occurredAt, timeZone: zone)
            )
        }.sorted { $0.occurredAt > $1.occurredAt }

        for reportingZone in ["Asia/Singapore", "America/Los_Angeles"] {
            let calendar = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: reportingZone)
            // The audited per-entry algorithm, kept here as the oracle.
            let reference = Dictionary(grouping: entries) {
                calendar.startOfDay(for: $0.originContext.attributedDate(in: calendar) ?? $0.occurredAt)
            }
            .map { (date: $0.key, ids: $0.value.map { $0.id }) }
            .sorted { $0.date > $1.date }
            let grouped = HistoryDayGroup.grouped(entries, calendar: calendar)
            XCTAssertEqual(grouped.map { $0.date }, reference.map { $0.date }, reportingZone)
            XCTAssertEqual(grouped.map { $0.entries.map { $0.id } }, reference.map { $0.ids }, reportingZone)
        }
        XCTAssertTrue(HistoryDayGroup.grouped([], calendar: singapore).isEmpty)
    }

    // MARK: - Calendar grid

    func testCalendarGridIsLocalizedAndStartsTheWeekWhereTheRegionDoes() throws {
        let september = try sgt(2026, 9, 18, 12)   // 1 September 2026 is a Tuesday.
        let sundayFirst = CalendarMonthLayout(
            month: september, calendar: singapore, firstWeekday: 1, locale: Locale(identifier: "en")
        )
        XCTAssertEqual(sundayFirst.weekdaySymbols, ["S", "M", "T", "W", "T", "F", "S"])
        XCTAssertEqual(sundayFirst.cells.prefix { $0 == nil }.count, 2)

        let mondayFirst = CalendarMonthLayout(
            month: september, calendar: singapore, firstWeekday: 2, locale: Locale(identifier: "zh-Hans")
        )
        XCTAssertEqual(mondayFirst.weekdaySymbols, ["一", "二", "三", "四", "五", "六", "日"])
        XCTAssertEqual(mondayFirst.cells.prefix { $0 == nil }.count, 1)
        XCTAssertEqual(mondayFirst.cells.compactMap { $0 }.count, 30)
    }

    func testCalendarDayNumeralsAreBareAndStayInTheReportingZoneWhileTravelling() throws {
        let layout = CalendarMonthLayout(
            month: try sgt(2026, 9, 1), calendar: singapore, firstWeekday: 1, locale: Locale(identifier: "zh-Hans")
        )
        try withDeviceTimeZone("America/Los_Angeles") {
            let numerals = layout.cells.compactMap { $0 }.map { CalendarMonthLayout.dayNumeral($0, calendar: singapore) }
            // Never "18日" (truncated to "1…" in the circle) and never shifted to "31".
            XCTAssertEqual(numerals, (1...30).map(String.init))
            let title = try sgt(2026, 9, 1).formattedForReporting(
                .dateTime.year().month(.wide), calendar: singapore, locale: Locale(identifier: "en")
            )
            XCTAssertTrue(title.contains("September"), title)
        }
    }

    func testCalendarLayoutSurvivesDaylightSavingLeapYearsAndSkippedDays() throws {
        for (zone, year, month, dayCount) in [
            ("America/Havana", 2026, 3, 31),       // midnight does not exist on 8 March
            ("Europe/London", 2026, 10, 31),       // a 25-hour day
            ("America/Los_Angeles", 2028, 2, 29)   // leap February
        ] {
            let calendar = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: zone)
            let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12)))
            let layout = CalendarMonthLayout(month: anchor, calendar: calendar, firstWeekday: 2, locale: Locale(identifier: "en"))
            let numerals = layout.cells.compactMap { $0 }.map { CalendarMonthLayout.dayNumeral($0, calendar: calendar) }
            XCTAssertEqual(numerals, (1...dayCount).map(String.init), zone)
        }
        // Samoa skipped 30 December 2011: an empty cell keeps the 31st in its weekday column.
        let apia = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "Pacific/Apia")
        let december = try XCTUnwrap(apia.date(from: DateComponents(year: 2011, month: 12, day: 15, hour: 12)))
        let layout = CalendarMonthLayout(month: december, calendar: apia, firstWeekday: 1, locale: Locale(identifier: "en"))
        let tail = layout.cells.suffix(3).map { $0.map { CalendarMonthLayout.dayNumeral($0, calendar: apia) } }
        XCTAssertEqual(tail, ["29", nil, "31"])
        let last = try XCTUnwrap(layout.cells.last ?? nil)
        XCTAssertEqual((layout.cells.count - 1) % 7 + 1, apia.component(.weekday, from: last))
    }

    func testCalendarLayoutFallsBackForAnInvalidFirstWeekday() throws {
        let layout = CalendarMonthLayout(
            month: try sgt(2026, 2, 10), calendar: singapore, firstWeekday: 9, locale: Locale(identifier: "en")
        )
        XCTAssertEqual(layout.weekdaySymbols.count, 7)
        XCTAssertEqual(layout.weekdaySymbols.first, "S")
        XCTAssertEqual(layout.cells.compactMap { $0 }.count, 28)
    }

    // MARK: - Log's recent-entry capsules

    @MainActor
    func testRecentEntryAmountsUseDisplayMinorUnitsAndAnExplicitCode() throws {
        try withAmountsHidden(false) {
            let sgd = try Money(try XCTUnwrap(Decimal(string: "18.6")), currency: CurrencyCode("SGD"))
            let label = historyPreloadAmountLabel(sgd)
            XCTAssertEqual(label, formattedMoneyWithCurrencyCode(sgd))
            XCTAssertTrue(label.contains("18.60") && label.contains("SGD"), label)

            let yen = try Money(1200, currency: CurrencyCode("JPY"))
            XCTAssertFalse(historyPreloadAmountLabel(yen).contains("."), historyPreloadAmountLabel(yen))
            let dinar = try Money(try XCTUnwrap(Decimal(string: "1.5")), currency: CurrencyCode("KWD"))
            XCTAssertTrue(historyPreloadAmountLabel(dinar).contains("1.500"), historyPreloadAmountLabel(dinar))
        }
        try withAmountsHidden(true) {
            let sgd = try Money(12, currency: CurrencyCode("SGD"))
            XCTAssertEqual(historyPreloadAmountLabel(sgd), MoneyAmountPrivacy.placeholder)
        }
        XCTAssertEqual(
            historyPreloadAmountLabel(nil),
            AppLocalization.string("quick_log.preload_amount_uncertain")
        )
    }

    // MARK: - History's summary leads with what the scope spent

    func testHistorySummaryHeadlineShowsSpendingOnlyForOneCurrency() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let spent = try XCTUnwrap(Decimal(string: "125.10"))
        let single = HistorySummary(
            transactionCount: 5, amountsByCurrency: [sgd: -spent],
            spendingByCurrency: [sgd: spent], incomeByCurrency: [:], refundsByCurrency: [:]
        )
        XCTAssertEqual(HistorySummaryHeadline.spending(single), try Money(spent, currency: sgd))

        // Mixed currencies are never summed into one headline.
        let mixed = HistorySummary(
            transactionCount: 2, amountsByCurrency: [sgd: -10, usd: 5],
            spendingByCurrency: [sgd: 10], incomeByCurrency: [usd: 5], refundsByCurrency: [:]
        )
        XCTAssertNil(HistorySummaryHeadline.spending(mixed))

        // Nothing spent (income or refunds only, or an empty scope) shows no headline.
        let incomeOnly = HistorySummary(
            transactionCount: 1, amountsByCurrency: [sgd: 50], incomeByCurrency: [sgd: 50]
        )
        XCTAssertNil(HistorySummaryHeadline.spending(incomeOnly))
        let refundOnly = HistorySummary(
            transactionCount: 1, amountsByCurrency: [sgd: 8], spendingByCurrency: [sgd: 0], refundsByCurrency: [sgd: 8]
        )
        XCTAssertNil(HistorySummaryHeadline.spending(refundOnly))
        XCTAssertNil(HistorySummaryHeadline.spending(HistorySummary(transactionCount: 0, amountsByCurrency: [:])))
    }

    // MARK: - Assets group totals follow the net-worth rules

    func testAssetsGroupSubtotalNetsDebtAndExcludesRestrictedValue() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let card = LedgerAccount(name: "Visa", kind: .liability, currency: sgd, accountType: .creditCard)
        let meal = LedgerAccount(name: "Meal card", kind: .asset, currency: sgd, accountType: .restrictedAllowance)
        // Liabilities are presented as positive amounts owed.
        let net = AccountCurrencyGroup.net([
            (account: bank, balance: .available(try Money(5000, currency: sgd))),
            (account: card, balance: .available(try Money(1200, currency: sgd))),
            (account: meal, balance: .available(try Money(300, currency: sgd)))
        ], currency: sgd)
        XCTAssertEqual(net, try Money(3800, currency: sgd), "the audited build showed 6,500")

        // Debt above cash is a negative net, never a larger sum.
        XCTAssertEqual(AccountCurrencyGroup.net([
            (account: bank, balance: .available(try Money(100, currency: sgd))),
            (account: card, balance: .available(try Money(250, currency: sgd)))
        ], currency: sgd), try Money(-150, currency: sgd))

        // Only restricted value: no subtotal rather than a misleading zero.
        XCTAssertNil(AccountCurrencyGroup.net(
            [(account: meal, balance: .available(try Money(300, currency: sgd)))], currency: sgd
        ))
        // An unavailable or foreign balance withholds the subtotal instead of guessing.
        XCTAssertNil(AccountCurrencyGroup.net(
            [(account: bank, balance: .unavailable(.amountCalculationFailed))], currency: sgd
        ))
        XCTAssertNil(AccountCurrencyGroup.net(
            [(account: bank, balance: .available(try Money(1, currency: CurrencyCode("USD"))))], currency: sgd
        ))
        XCTAssertNil(AccountCurrencyGroup.net([], currency: sgd))
    }

    // MARK: - Budget replay reads an unattributed row on its origin day

    @MainActor
    private func singaporeBudgetModel(_ fixture: AppModelFixture) throws -> (model: AppModel, august: Date) {
        let august = try sgt(2026, 8, 1)
        let budget = BudgetNode(
            id: fixture.food.id, name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd), purpose: .flexible
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(effectiveMonth: august, nodes: [budget])]
        )
        let model = fixture.model(
            profile: UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore"),
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        return (model, august)
    }

    private func foodExpense(
        _ fixture: AppModelFixture, at instant: Date, origin: TransactionOriginContext, amount: Decimal = 50
    ) throws -> JournalEntry {
        try JournalEntry(kind: .expense, occurredAt: instant, postings: [
            Posting(accountID: fixture.wallet.id, money: try Money(-amount, currency: fixture.sgd)),
            Posting(accountID: fixture.food.id, money: try Money(amount, currency: fixture.sgd))
        ], originContext: origin)
    }

    @MainActor
    func testALegacyRowNearMidnightAffectsTheMonthOfItsOriginDay() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let (model, august) = try singaporeBudgetModel(fixture)
        // 04:00 on 1 Sep in Singapore is still 31 Aug in UTC: the day a legacy
        // row's inferred origin, the indexed replay and reports all use.
        let instant = try sgt(2026, 9, 1, 4)
        let legacy = try foodExpense(fixture, at: instant, origin: .inferredUTC(for: instant))
        XCTAssertEqual(legacy.originContext.dayKey, 20260831)
        XCTAssertEqual(try model.budgetAffectedMonth(for: legacy, attribution: nil), august)
    }

    @MainActor
    func testInMemoryBudgetReplayMatchesTheIndexedReplayForMixedOrigins() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let (model, august) = try singaporeBudgetModel(fixture)
        let zones = ["UTC", "Asia/Singapore", "America/New_York", "Pacific/Kiritimati", "Pacific/Pago_Pago"]
        var random = SplitMix64(seed: 0x7202)
        var entries: [JournalEntry] = []
        for _ in 0..<240 {
            // Instants within a day either side of the Sep 1 and Oct 1 boundaries.
            let boundary = try sgt(2026, random.next() % 2 == 0 ? 9 : 10, 1)
            let instant = boundary + TimeInterval(Int(random.next() % 172_800) - 86_400)
            let pick = Int(random.next() % UInt64(zones.count + 1))
            let origin: TransactionOriginContext
            if pick == zones.count {
                origin = .inferredUTC(for: instant)
            } else {
                origin = .capture(for: instant, timeZone: try XCTUnwrap(TimeZone(identifier: zones[pick])))
            }
            entries.append(try foodExpense(
                fixture, at: instant, origin: origin, amount: Decimal(Int(random.next() % 90) + 1)
            ))
        }
        let events = entries.flatMap { entry in
            entry.postings.map {
                LedgerPostingEvent(
                    entryID: entry.id, occurredAt: entry.occurredAt,
                    originDayKey: entry.originContext.dayKey, posting: $0
                )
            }
        }
        let november = try sgt(2026, 11, 1)
        let inMemory = try model.closedMonthBudgetSpending(
            entries: entries, attributions: [:], currency: fixture.sgd, replayStart: august,
            currentMonthStart: november, calendar: model.reportingCalendar, excludingEntryIDs: []
        )
        let indexed = try model.closedMonthBudgetSpending(
            events: events, attributions: [:], currency: fixture.sgd, replayStart: august,
            currentMonthStart: november, calendar: model.reportingCalendar, excludingEntryIDs: []
        )
        XCTAssertEqual(inMemory, indexed)
        XCTAssertEqual(inMemory.count, 3, "August, September and October each hold spending")
    }

    // MARK: - A loan paid past zero stays usable

    @MainActor
    func testAnOverpaidLoanStillTakesInterestAndCanBeFinished() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let loan = LedgerAccount(name: "Car loan", kind: .liability, currency: fixture.sgd, accountType: .loan)
        let model = fixture.model(accounts: [fixture.wallet, loan, fixture.food])
        let opened = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let day: TimeInterval = 86_400
        let loanID = try await model.addLoanPlan(
            accountID: loan.id, name: "Car loan", originalPrincipal: 100, openedAt: opened,
            annualPercentageRate: nil, termMonths: nil, includeInTotalDebt: true,
            interestExpenseAccountID: fixture.food.id, feeExpenseAccountID: nil
        )
        // The advance, then an ordinary transfer that pays 30 past zero.
        _ = try await model.logTransfer(
            amount: 100, sourceAccountID: loan.id, destinationAccountID: fixture.wallet.id,
            occurredAt: opened, payee: nil, note: nil
        )
        _ = try await model.logTransfer(
            amount: 130, sourceAccountID: fixture.wallet.id, destinationAccountID: loan.id,
            occurredAt: opened + day, payee: nil, note: nil
        )
        let plan = try XCTUnwrap(model.loanPlans.first { $0.id == loanID })
        guard case let .available(summary) = model.loanSummary(plan) else {
            return XCTFail("An overpaid loan must still summarise")
        }
        XCTAssertEqual(summary.remainingPrincipal.amount, -30)
        XCTAssertEqual(summary.principalPaid.amount, 100)

        // Interest still posts, while more principal would only deepen the credit.
        try await model.recordLoanPayment(
            loanID: loanID, paidFrom: fixture.wallet.id, principal: 0, interest: 2, fees: 0,
            occurredAt: opened + 2 * day, note: nil
        )
        do {
            try await model.recordLoanPayment(
                loanID: loanID, paidFrom: fixture.wallet.id, principal: 1, interest: 0, fees: 0,
                occurredAt: opened + 2 * day, note: nil
            )
            XCTFail("Principal beyond the balance owed must be refused")
        } catch AppModelError.loanOverpayment {}
        try await model.finishLoan(id: loanID, at: opened + 3 * day)
        XCTAssertNotNil(model.loanPlans.first { $0.id == loanID }?.closedAt)
        await fixture.store.close()
    }

    func testTodayHeroNamesItsPinnedScopeInBothLanguages() {
        XCTAssertEqual(PinnedRemainingHero.scopeText(categoryCount: 1, language: .english), "Across 1 pinned category")
        XCTAssertEqual(PinnedRemainingHero.scopeText(categoryCount: 4, language: .english), "Across 4 pinned categories")
        XCTAssertEqual(PinnedRemainingHero.scopeText(categoryCount: 4, language: .simplifiedChinese), "4 个置顶分类合计")
        XCTAssertEqual(PinnedRemainingHero.scopeText(categoryCount: 1, language: .simplifiedChinese), "1 个置顶分类")
    }

    // MARK: - Today's share on the pinned hero never outruns what is left

    private func pinned(
        _ name: String, left: Decimal, purpose: BudgetPurpose, daily: Decimal?
    ) throws -> PinnedBudgetSummary {
        let sgd = try CurrencyCode("SGD")
        let limit = try Money(300, currency: sgd)
        let progress = BudgetProgress(
            node: BudgetNode(id: UUID(), name: name, limit: limit, purpose: purpose),
            effectiveLimit: limit,
            spent: try Money(300 - left, currency: sgd),
            remaining: try Money(left, currency: sgd)
        )
        let interval = DateInterval(start: Date(timeIntervalSinceReferenceDate: 0), duration: 86_400)
        let spread = try daily.map { amount in
            let pace = BudgetPace(
                cadence: .daily, available: try Money(amount, currency: sgd),
                interval: interval, remainingDayCount: 10
            )
            return BudgetPaceSpread(monthly: pace, weekly: pace, daily: pace)
        }
        return PinnedBudgetSummary(progress: progress, purpose: purpose, spread: spread)
    }

    func testPinnedHeroShowsTodayOnlyWhenEveryCategoryIsFlexibleWithMoneyLeft() throws {
        let everyday = try pinned("Everyday", left: 300, purpose: .flexible, daily: 30)
        let lifestyle = try pinned("Lifestyle", left: 100, purpose: .flexible, daily: 10)
        let hero = try XCTUnwrap(PinnedRemainingHero.make([everyday, lifestyle]))
        XCTAssertEqual(hero.remaining.amount, 400)
        XCTAssertEqual(hero.today?.amount, 40)

        // Lifestyle is S$200 over: S$30 a day for ten days would overspend
        // the pinned set, whose honest remainder is only S$100.
        let overspent = try pinned("Lifestyle", left: -200, purpose: .flexible, daily: nil)
        let netted = try XCTUnwrap(PinnedRemainingHero.make([everyday, overspent]))
        XCTAssertEqual(netted.remaining.amount, 100)
        XCTAssertNil(netted.today)

        // Rent is a commitment; an even split of it is not a daily allowance.
        let rent = try pinned("Rent", left: 1_500, purpose: .commitment, daily: 150)
        XCTAssertNil(try XCTUnwrap(PinnedRemainingHero.make([everyday, rent])).today)
    }

    // MARK: - Amounts are never read at a smaller scale than they were written

    func testGroupedThousandsAreRefusedRatherThanReadAsDecimals() throws {
        let us = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")
        let (vnd, idr, jpy) = (try CurrencyCode("VND"), try CurrencyCode("IDR"), try CurrencyCode("JPY"))
        let (eur, kwd, usd) = (try CurrencyCode("EUR"), try CurrencyCode("KWD"), try CurrencyCode("USD"))
        // Each of these once saved a thousandth of the amount.
        XCTAssertNil(moneyAmount(from: "50.000", currency: vnd, locale: us))
        XCTAssertNil(moneyAmount(from: "25.000", currency: idr, locale: us))
        XCTAssertNil(moneyAmount(from: "25.000", currency: idr, locale: Locale(identifier: "id_ID")))
        XCTAssertNil(moneyAmount(from: "3.000", currency: jpy, locale: Locale(identifier: "ja_JP")))
        XCTAssertNil(moneyAmount(from: "1.000", currency: eur, locale: de))
        XCTAssertNil(moneyAmount(from: "1.250", currency: eur, locale: de))
        // Where "." groups thousands, a three-digit tail is ambiguous in any field.
        XCTAssertNil(decimalAmount(from: "4.125", locale: de))
        XCTAssertEqual(decimalAmount(from: "4,125", locale: de), try XCTUnwrap(Decimal(string: "4.125")))
        // Unambiguous input still reads exactly, at every currency scale.
        XCTAssertEqual(moneyAmount(from: "1.5", currency: eur, locale: de), try XCTUnwrap(Decimal(string: "1.5")))
        XCTAssertEqual(moneyAmount(from: "1,50", currency: eur, locale: de), try XCTUnwrap(Decimal(string: "1.5")))
        XCTAssertEqual(moneyAmount(from: " 12.50 ", currency: usd, locale: us), try XCTUnwrap(Decimal(string: "12.5")))
        XCTAssertEqual(moneyAmount(from: "1.000", currency: kwd, locale: us), 1)
        XCTAssertEqual(moneyAmount(from: "1,250", currency: kwd, locale: de), try XCTUnwrap(Decimal(string: "1.25")))
        XCTAssertEqual(moneyAmount(from: "25000", currency: idr, locale: us), 25_000)
        XCTAssertEqual(moneyAmount(from: "7", currency: nil, locale: us), 7)
        XCTAssertEqual(
            moneyAmount(from: "0.00000001", currency: try CurrencyCode("BTC"), locale: us),
            try XCTUnwrap(Decimal(string: "0.00000001"))
        )
        // A pasted 40-digit tail no longer truncates silently to 0.1.
        XCTAssertNil(moneyAmount(from: "0.1000000000000000000000000000000000000001", currency: usd, locale: us))
        XCTAssertEqual(
            writtenAmount(from: "-12.5", locale: us),
            WrittenAmount(value: try XCTUnwrap(Decimal(string: "-12.5")), fractionDigits: 1)
        )
    }

    func testMidTypingPrefixesAreIncompleteRatherThanInvalid() {
        let us = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")
        for text in ["12.", "0", "0.", "0.0", " 0.00 "] {
            XCTAssertTrue(isIncompleteAmount(text, locale: us), text)
        }
        for text in ["12,", "0,", "12."] {
            XCTAssertTrue(isIncompleteAmount(text, locale: de), text)
        }
        for text in ["", "12", "12.5", "1.2.3", "abc", ".", "-", "12,", "25.000"] {
            XCTAssertFalse(isIncompleteAmount(text, locale: us), text)
        }
    }

    // MARK: - A split row never passes its total off as one category

    func testSplitRowsCountDistinctCategoriesWithinTheirScope() throws {
        let sgd = try CurrencyCode("SGD")
        let wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let home = LedgerAccount(name: "Home", kind: .expense)
        let accounts = Dictionary(uniqueKeysWithValues: [wallet, food, home].map { ($0.id, $0) })
        func expense(_ legs: [(LedgerAccount, Decimal)]) throws -> JournalEntry {
            let total = legs.reduce(Decimal.zero) { $0 + $1.1 }
            return try JournalEntry(kind: .expense, postings: [
                Posting(accountID: wallet.id, money: try Money(-total, currency: sgd))
            ] + legs.map { Posting(accountID: $0.0.id, money: try Money($0.1, currency: sgd)) })
        }
        let ikea = try expense([(food, 60), (home, 40)])
        XCTAssertEqual(TransactionRowCategories.ids(of: ikea, accountsByID: accounts, within: nil), [food.id, home.id])
        // Inside one budget category's history only its own leg explains the row.
        XCTAssertEqual(TransactionRowCategories.ids(of: ikea, accountsByID: accounts, within: [home.id]), [home.id])
        // Two legs in one category are not a split.
        let groceries = try expense([(food, 60), (food, 40)])
        XCTAssertEqual(TransactionRowCategories.ids(of: groceries, accountsByID: accounts, within: nil), [food.id])

        XCTAssertEqual(
            String(format: AppLocalization.string("history.split_more_format", language: .english), "Food", 1),
            "Food + 1 more"
        )
        XCTAssertEqual(
            String(format: AppLocalization.string("history.split_title_format", language: .simplifiedChinese), 2),
            "拆分 · 2 个分类"
        )
    }

    // MARK: - The Log draft never loses a capture or keeps a deleted category

    private func blankDraft(accountID: UUID? = nil, categoryID: UUID? = nil) -> QuickLogDraft {
        QuickLogDraft(
            kind: .expense, amountText: "", destinationAmountText: "",
            accountID: accountID, destinationAccountID: nil, categoryID: categoryID,
            occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000), dateWasEdited: false,
            payee: "", note: "", smartText: ""
        )
    }

    @MainActor
    func testOpeningAWaitingCaptureSurvivesABlankFormLaunchingOverIt() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(kind: .expense, amountText: "18", payee: "Taxi")
        let model = fixture.model(lockedCaptureStore: InMemoryLockedCaptureStore(captures: [capture]))
        let beforeOpen = model.quickLogPreparationRevision
        try await model.reviewPendingLockedCapturesForBackup()
        let promoted = try XCTUnwrap(model.quickLogDraft)
        XCTAssertEqual(promoted.sourceCaptureID, capture.id)
        XCTAssertNotEqual(model.quickLogPreparationRevision, beforeOpen, "A visible Log form must adopt the capture")

        // The form had not adopted it yet and launches with its blank snapshot:
        // the audited build replaced the capture's only remaining copy.
        let beforeLaunch = model.quickLogPreparationRevision
        model.updateQuickLogDraft(blankDraft())
        XCTAssertEqual(model.quickLogDraft, promoted)
        XCTAssertNotEqual(model.quickLogPreparationRevision, beforeLaunch)

        // Once adopted, the capture draft is edited normally.
        var edited = promoted
        edited.note = "Airport"
        model.updateQuickLogDraft(edited)
        XCTAssertEqual(model.quickLogDraft, edited)
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }

    @MainActor
    func testAStaleFormCannotPersistAMergedCategoryIntoABackup() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let snacks = LedgerAccount(name: "Snacks", kind: .expense)
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, snacks, salary]
        let stale = blankDraft(accountID: fixture.wallet.id, categoryID: snacks.id)
        try await fixture.seed(profile: profile, accounts: accounts, quickLogDraft: stale)
        let model = fixture.model(profile: profile, accounts: accounts, quickLogDraft: stale)
        try await model.mergeLedgerItem(id: snacks.id, into: fixture.food.id)
        XCTAssertNotEqual(model.quickLogDraft?.categoryID, snacks.id)

        // The Log form still holds Snacks; its next keystroke must not bring it back.
        var typed = stale
        typed.amountText = "4"
        typed.splitLines = [
            QuickLogSplitDraftLine(categoryID: salary.id, amountText: "2"),
            QuickLogSplitDraftLine(categoryID: fixture.food.id, amountText: "2")
        ]
        let beforeTyping = model.quickLogPreparationRevision
        model.updateQuickLogDraft(typed)
        let saved = try XCTUnwrap(model.quickLogDraft)
        XCTAssertNil(saved.categoryID)
        XCTAssertEqual(saved.accountID, fixture.wallet.id)
        XCTAssertEqual(saved.splitLines.map(\.categoryID), [nil, fixture.food.id])
        XCTAssertNotEqual(model.quickLogPreparationRevision, beforeTyping, "The form re-syncs to the repaired draft")
        // Restore rejects a whole book over a bad draft; this one passes.
        XCTAssertNoThrow(try RestoreCandidateValidator.validateRelationshipDraft(
            saved, accountByID: model.accountsByID
        ))
        await model.waitForPendingQuickLogDraftFlush()
        await fixture.store.close()
    }

    // MARK: - A requested lock keeps the book covered while it waits

    @MainActor
    func testADeferredManualLockKeepsTheCoverThroughAShortInactiveVisit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.usAccount, fixture.food])
        let gate = CheckpointGate()
        let model = fixture.model(profile: profile, lifecycleHooks: AppModelLifecycleHooks { checkpoint in
            guard checkpoint == .beforeRestoreCommit else { return }
            await gate.suspend()
        })
        let archive = try await model.encryptedBackup(password: "restore-password")
        let restore = Task { @MainActor in
            try await model.restoreEncryptedBackup(archive, password: "restore-password")
        }
        await gate.waitUntilReached()

        model.lockManually()
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)
        // A glance at Notification Center while the restore drains.
        let inactiveAt = Date(timeIntervalSinceReferenceDate: 50_000)
        model.sceneDidBecomeInactive(at: inactiveAt)
        model.sceneDidBecomeActive(at: inactiveAt.addingTimeInterval(1))
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover, "The decoded book stays covered until the lock runs")

        await gate.release()
        try await restore.value
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
    }
}

/// Deterministic generator so the randomized book is identical on every run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Pauses a lifecycle checkpoint until the test releases it.
private actor CheckpointGate {
    private var reached = false
    private var released = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        reached = true
        reachWaiters.forEach { $0.resume() }
        reachWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
