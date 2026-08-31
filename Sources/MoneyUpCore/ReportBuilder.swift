import Foundation

public extension FinanceCalculator {
    /// Currency-labeled flow for one half-open day/window. Empty input returns
    /// no rows rather than a fabricated base-currency zero.
    static func dailyFlows(
        interval: DateInterval,
        accounts: [LedgerAccount],
        entries: [JournalEntry],
        baseCurrency: CurrencyCode,
        calendar: Calendar = FinancialPeriodBoundary.gregorianCalendar()
    ) throws -> [CurrencyFlow] {
        let report = try self.report(
            interval: interval,
            accounts: accounts,
            entries: entries,
            baseCurrency: baseCurrency,
            calendar: calendar
        )
        return ([report.baseFlow] + report.foreignFlows).filter { !$0.isEmpty }
    }

    /// Builds a full period report in one pass over the journal.
    ///
    /// Reporting used to rescan every entry once per figure on screen, and
    /// silently discarded postings that were not in the base currency. This
    /// keeps every currency, and separates the ones that cannot be summed
    /// together instead of dropping them.
    static func report(
        interval: DateInterval,
        trendInterval: DateInterval? = nil,
        accounts: [LedgerAccount],
        entries: [JournalEntry],
        baseCurrency: CurrencyCode,
        calendar: Calendar = .current
    ) throws -> PeriodReport {
        try report(
            interval: interval,
            trendInterval: trendInterval,
            accounts: accounts,
            postingEvents: entries.flatMap { entry in
                entry.postings.map {
                    LedgerPostingEvent(
                        entryID: entry.id,
                        occurredAt: entry.occurredAt,
                        originDayKey: entry.originContext.dayKey,
                        posting: $0
                    )
                }
            },
            baseCurrency: baseCurrency,
            calendar: calendar
        )
    }

    /// Builds the same exact report from the encrypted store's normalized
    /// posting projection. This keeps reporting independent of full journal
    /// JSON and is deliberately public so app startup can prepare its compact
    /// Today/Insights state without retaining the whole journal.
    static func report(
        interval: DateInterval,
        trendInterval: DateInterval? = nil,
        accounts: [LedgerAccount],
        postingEvents: [LedgerPostingEvent],
        baseCurrency: CurrencyCode,
        calendar: Calendar = .current
    ) throws -> PeriodReport {
        let trend = trendInterval ?? interval
        var kinds: [UUID: LedgerAccountKind] = [:]
        var names: [UUID: String] = [:]
        for account in accounts {
            kinds[account.id] = account.kind
            names[account.id] = account.name
        }
        var accumulator = ReportAccumulator()
        for event in postingEvents {
            try accumulator.record(
                event,
                accountKinds: kinds,
                interval: interval,
                trend: trend,
                baseCurrency: baseCurrency,
                calendar: calendar
            )
        }
        let flows = try accumulator.currencyFlows(baseCurrency: baseCurrency)
        let baseFlow = flows.first { $0.currency == baseCurrency }
            ?? CurrencyFlow(
                currency: baseCurrency,
                income: Money.zero(currency: baseCurrency),
                expense: Money.zero(currency: baseCurrency),
                net: Money.zero(currency: baseCurrency)
            )
        let foreignFlows = flows
            .filter { $0.currency != baseCurrency && !$0.isEmpty }
            .sorted { $0.currency < $1.currency }
        return PeriodReport(
            interval: interval,
            trendInterval: trend,
            baseCurrency: baseCurrency,
            baseFlow: baseFlow,
            foreignFlows: foreignFlows,
            categorySpending: try accumulator.categorySpending(
                names: names,
                baseCurrency: baseCurrency
            ),
            monthlyFlows: try accumulator.monthlyFlows(
                trend: trend,
                baseCurrency: baseCurrency,
                calendar: calendar
            )
        )
    }

    private struct ReportAccumulator {
        var income: [CurrencyCode: Decimal] = [:]
        var expense: [CurrencyCode: Decimal] = [:]
        var categoryTotals: [UUID: Decimal] = [:]
        var monthlyIncome: [Date: Decimal] = [:]
        var monthlyExpense: [Date: Decimal] = [:]

        mutating func record(
            _ event: LedgerPostingEvent,
            accountKinds: [UUID: LedgerAccountKind],
            interval: DateInterval,
            trend: DateInterval,
            baseCurrency: CurrencyCode,
            calendar: Calendar
        ) throws {
            let date = event.attributedDate(in: calendar) ?? event.occurredAt
            let inPeriod = FinancialPeriodBoundary.contains(date, in: interval)
            let inTrend = FinancialPeriodBoundary.contains(date, in: trend)
            guard inPeriod || inTrend else { return }
            let posting = event.posting
            guard let kind = accountKinds[posting.accountID],
                  kind == .income || kind == .expense else { return }
            let currency = posting.money.currency
            let amount = kind == .income ? -posting.money.amount : posting.money.amount
            if inPeriod {
                try recordPeriod(
                    kind: kind,
                    posting: posting,
                    amount: amount,
                    baseCurrency: baseCurrency
                )
            }
            guard inTrend,
                  currency == baseCurrency,
                  let month = calendar.dateInterval(of: .month, for: date)?.start else {
                return
            }
            if kind == .income {
                monthlyIncome[month] = try CheckedDecimal.adding(
                    monthlyIncome[month] ?? .zero,
                    amount
                )
            } else {
                monthlyExpense[month] = try CheckedDecimal.adding(
                    monthlyExpense[month] ?? .zero,
                    amount
                )
            }
        }

        mutating func recordPeriod(
            kind: LedgerAccountKind,
            posting: Posting,
            amount: Decimal,
            baseCurrency: CurrencyCode
        ) throws {
            let currency = posting.money.currency
            if kind == .income {
                income[currency] = try CheckedDecimal.adding(
                    income[currency] ?? .zero,
                    amount
                )
                return
            }
            expense[currency] = try CheckedDecimal.adding(
                expense[currency] ?? .zero,
                amount
            )
            if currency == baseCurrency {
                categoryTotals[posting.accountID] = try CheckedDecimal.adding(
                    categoryTotals[posting.accountID] ?? .zero,
                    amount
                )
            }
        }

        func currencyFlows(baseCurrency: CurrencyCode) throws -> [CurrencyFlow] {
            var currencies = Set(income.keys)
            currencies.formUnion(expense.keys)
            currencies.insert(baseCurrency)
            return try currencies.map { currency in
                let earned = income[currency] ?? .zero
                let spent = expense[currency] ?? .zero
                return CurrencyFlow(
                    currency: currency,
                    income: try Money(earned, currency: currency),
                    expense: try Money(spent, currency: currency),
                    net: try Money(
                        CheckedDecimal.subtracting(earned, spent),
                        currency: currency
                    )
                )
            }
        }

        func categorySpending(
            names: [UUID: String],
            baseCurrency: CurrencyCode
        ) throws -> [CategorySpending] {
            try categoryTotals.map { accountID, amount in
                CategorySpending(
                    accountID: accountID,
                    name: names[accountID] ?? "",
                    amount: try Money(amount, currency: baseCurrency)
                )
            }.sorted(by: Self.categoryOrder)
        }

        static func categoryOrder(
            _ first: CategorySpending,
            _ second: CategorySpending
        ) -> Bool {
            if first.amount.amount != second.amount.amount {
                return first.amount.amount > second.amount.amount
            }
            if first.name != second.name { return first.name < second.name }
            return first.accountID.uuidString < second.accountID.uuidString
        }

        func monthlyFlows(
            trend: DateInterval,
            baseCurrency: CurrencyCode,
            calendar: Calendar
        ) throws -> [MonthlyFlow] {
            try FinanceCalculator.monthStarts(in: trend, calendar: calendar).map { month in
                let earned = monthlyIncome[month] ?? .zero
                let spent = monthlyExpense[month] ?? .zero
                return MonthlyFlow(
                    month: month,
                    income: try Money(earned, currency: baseCurrency),
                    expense: try Money(spent, currency: baseCurrency),
                    net: try Money(
                        CheckedDecimal.subtracting(earned, spent),
                        currency: baseCurrency
                    )
                )
            }
        }
    }

    /// Every account balance, per currency, in one pass.
    ///
    /// Screens that list accounts previously rescanned the whole journal once
    /// per account.
    static func balancesByAccount(
        entries: [JournalEntry]
    ) throws -> [UUID: [CurrencyCode: Money]] {
        var totals: [UUID: [CurrencyCode: Decimal]] = [:]

        for entry in entries {
            for posting in entry.postings {
                let accountID = posting.accountID
                let currency = posting.money.currency
                var accountTotals = totals[accountID] ?? [:]
                accountTotals[currency] = try CheckedDecimal.adding(
                    accountTotals[currency] ?? .zero,
                    posting.money.amount
                )
                totals[accountID] = accountTotals
            }
        }

        return try totals.reduce(into: [:]) { result, item in
            result[item.key] = try item.value.reduce(
                into: [CurrencyCode: Money]()
            ) { balances, pair in
                balances[pair.key] = try Money(pair.value, currency: pair.key)
            }
        }
    }

    private static func monthStarts(
        in interval: DateInterval,
        calendar: Calendar
    ) -> [Date] {
        guard var current = calendar.dateInterval(
            of: .month,
            for: interval.start
        )?.start else { return [] }

        var months: [Date] = []
        while current < interval.end {
            months.append(current)
            guard let next = calendar.date(
                byAdding: .month,
                value: 1,
                to: current
            ) else { break }
            current = next
        }
        return months
    }
}
