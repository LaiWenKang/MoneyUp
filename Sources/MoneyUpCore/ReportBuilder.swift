import Foundation

public extension FinanceCalculator {
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
        let trend = trendInterval ?? interval
        var kinds: [UUID: LedgerAccountKind] = [:]
        var names: [UUID: String] = [:]
        kinds.reserveCapacity(accounts.count)
        names.reserveCapacity(accounts.count)

        for account in accounts {
            kinds[account.id] = account.kind
            names[account.id] = account.name
        }

        var income: [CurrencyCode: Decimal] = [:]
        var expense: [CurrencyCode: Decimal] = [:]
        var categoryTotals: [UUID: Decimal] = [:]
        var monthlyIncome: [Date: Decimal] = [:]
        var monthlyExpense: [Date: Decimal] = [:]

        for entry in entries {
            let inPeriod = interval.containsHalfOpen(entry.occurredAt)
            let inTrend = trend.containsHalfOpen(entry.occurredAt)
            guard inPeriod || inTrend else { continue }

            let month: Date? = inTrend
                ? calendar.dateInterval(of: .month, for: entry.occurredAt)?.start
                : nil

            for posting in entry.postings {
                guard let kind = kinds[posting.accountID],
                      kind == .income || kind == .expense else { continue }

                let currency = posting.money.currency
                // Income accounts are credited, so their postings are negative.
                let amount = kind == .income
                    ? -posting.money.amount
                    : posting.money.amount

                if inPeriod {
                    if kind == .income {
                        income[currency, default: .zero] += amount
                    } else {
                        expense[currency, default: .zero] += amount
                        if currency == baseCurrency {
                            categoryTotals[posting.accountID, default: .zero] += amount
                        }
                    }
                }

                if let month, currency == baseCurrency {
                    if kind == .income {
                        monthlyIncome[month, default: .zero] += amount
                    } else {
                        monthlyExpense[month, default: .zero] += amount
                    }
                }
            }
        }

        var currencies = Set(income.keys)
        currencies.formUnion(expense.keys)
        currencies.insert(baseCurrency)

        var flows: [CurrencyFlow] = []
        flows.reserveCapacity(currencies.count)

        for currency in currencies {
            let incomeAmount = income[currency] ?? .zero
            let expenseAmount = expense[currency] ?? .zero
            let incomeMoney = try Money(incomeAmount, currency: currency)
            let expenseMoney = try Money(expenseAmount, currency: currency)
            let netMoney = try Money(incomeAmount - expenseAmount, currency: currency)
            flows.append(
                CurrencyFlow(
                    currency: currency,
                    income: incomeMoney,
                    expense: expenseMoney,
                    net: netMoney
                )
            )
        }

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

        var categorySpending: [CategorySpending] = []
        categorySpending.reserveCapacity(categoryTotals.count)

        for (accountID, amount) in categoryTotals {
            categorySpending.append(
                CategorySpending(
                    accountID: accountID,
                    name: names[accountID] ?? "",
                    amount: try Money(amount, currency: baseCurrency)
                )
            )
        }
        categorySpending.sort { first, second in
            if first.amount.amount == second.amount.amount {
                return first.name < second.name
            }
            return first.amount.amount > second.amount.amount
        }

        var monthlyFlows: [MonthlyFlow] = []

        for month in Self.monthStarts(in: trend, calendar: calendar) {
            let incomeAmount = monthlyIncome[month] ?? .zero
            let expenseAmount = monthlyExpense[month] ?? .zero
            monthlyFlows.append(
                MonthlyFlow(
                    month: month,
                    income: try Money(incomeAmount, currency: baseCurrency),
                    expense: try Money(expenseAmount, currency: baseCurrency),
                    net: try Money(incomeAmount - expenseAmount, currency: baseCurrency)
                )
            )
        }

        return PeriodReport(
            interval: interval,
            trendInterval: trend,
            baseCurrency: baseCurrency,
            baseFlow: baseFlow,
            foreignFlows: foreignFlows,
            categorySpending: categorySpending,
            monthlyFlows: monthlyFlows
        )
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
                totals[posting.accountID, default: [:]][
                    posting.money.currency,
                    default: .zero
                ] += posting.money.amount
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
