import Foundation
import MoneyUpCore
import MoneyUpIntelligence

extension AppModel {
    func monthEndProjectionResult(
        asOf requestedDate: Date? = nil
    ) async -> DerivedValue<[MonthEndProjection]> {
        guard state == .ready,
              profile?.intelligenceEnabled == true else {
            return .unavailable(.intelligenceProjectionUnavailable)
        }
        let asOf = requestedDate ?? currentDate()
        do {
            let context = try monthEndProjectionContext(asOf: asOf)
            let events = try await journalPostingEvents(in: context.actualsInterval)
            return .available(try monthEndProjections(
                events: events,
                context: context
            ))
        } catch {
            DerivedValueDiagnostics.record(
                .intelligenceProjectionUnavailable,
                operation: "intelligence-month-end-projection",
                error: error
            )
            return .unavailable(.intelligenceProjectionUnavailable)
        }
    }

    private func monthEndProjectionContext(
        asOf: Date
    ) throws -> MonthEndProjectionContext {
        let calendar = reportingCalendar
        guard let month = calendar.dateInterval(of: .month, for: asOf),
              let day = calendar.dateInterval(of: .day, for: asOf),
              let totalDays = calendar.range(of: .day, in: .month, for: asOf)?.count,
              let elapsed = calendar.dateComponents(
                  [.day],
                  from: month.start,
                  to: day.start
              ).day.map({ $0 + 1 }),
              elapsed >= MonthEndProjectionEngine.minimumElapsedDayCount else {
            throw AppModelError.invalidBook
        }
        return MonthEndProjectionContext(
            month: month,
            actualsInterval: DateInterval(
                start: month.start,
                end: min(day.end, month.end)
            ),
            asOfDayKey: FinancialPeriodBoundary.dayKey(
                for: asOf,
                calendar: calendar
            ),
            elapsedDayCount: elapsed,
            remainingDayCount: totalDays - elapsed
        )
    }

    private func monthEndProjections(
        events: [LedgerPostingEvent],
        context: MonthEndProjectionContext
    ) throws -> [MonthEndProjection] {
        let expenseIDs = Set(accounts.lazy.filter {
            $0.kind == .expense
        }.map(\.id))
        let flexibleIDs = Set(budgetPurposeOverview().effectivePurposeByID.compactMap {
            $0.value == .flexible ? $0.key : nil
        })
        let actuals = try spendingByCurrency(
            events: events,
            categoryIDs: expenseIDs
        )
        let flexible = try spendingByCurrency(
            events: events,
            categoryIDs: flexibleIDs
        )
        let schedules = try confirmedSchedulesByCurrency(context: context)
        let currencies = Set(actuals.keys).union(schedules.keys)
        return try currencies.sorted().map { currency in
            try MonthEndProjectionEngine.project(MonthEndProjectionInput(
                committedActuals: try Money(
                    actuals[currency] ?? .zero,
                    currency: currency
                ),
                remainingSchedules: try moneyValues(
                    schedules[currency],
                    currency: currency
                ),
                flexibleActuals: try moneyValues(
                    flexible[currency],
                    currency: currency
                ),
                elapsedDayCount: context.elapsedDayCount,
                remainingDayCount: context.remainingDayCount
            ))
        }
    }

    private func spendingByCurrency(
        events: [LedgerPostingEvent],
        categoryIDs: Set<UUID>
    ) throws -> [CurrencyCode: Decimal] {
        var result: [CurrencyCode: Decimal] = [:]
        for event in events where categoryIDs.contains(event.posting.accountID) {
            let money = event.posting.money
            result[money.currency] = try CheckedDecimal.adding(
                result[money.currency] ?? .zero,
                money.amount
            )
        }
        return result
    }

    private func confirmedSchedulesByCurrency(
        context: MonthEndProjectionContext
    ) throws -> [CurrencyCode: Decimal] {
        var result: [CurrencyCode: Decimal] = [:]
        for schedule in scheduledTransactions where schedule.kind == .expense
            && schedule.isActive && schedule.isCurrentOccurrenceConfirmed
            && schedule.nextOccurrence < context.month.end
            && FinancialPeriodBoundary.dayKey(
                for: schedule.nextOccurrence,
                calendar: reportingCalendar
            ) >= context.asOfDayKey {
            let money = schedule.amount
            result[money.currency] = try CheckedDecimal.adding(
                result[money.currency] ?? .zero,
                money.amount
            )
        }
        return result
    }

    private func moneyValues(
        _ amount: Decimal?,
        currency: CurrencyCode
    ) throws -> [Money] {
        guard let amount else { return [] }
        return [try Money(amount, currency: currency)]
    }
}

private struct MonthEndProjectionContext {
    let month: DateInterval
    let actualsInterval: DateInterval
    let asOfDayKey: Int
    let elapsedDayCount: Int
    let remainingDayCount: Int
}
