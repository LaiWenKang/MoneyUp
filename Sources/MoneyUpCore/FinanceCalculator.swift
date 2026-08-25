import Foundation

public enum FinanceCalculator {
    public static func balances(
        for accountID: UUID,
        entries: [JournalEntry]
    ) throws -> [CurrencyCode: Money] {
        var totals: [CurrencyCode: Decimal] = [:]

        for posting in entries.flatMap(\.postings)
        where posting.accountID == accountID {
            totals[posting.money.currency, default: .zero] += posting.money.amount
        }

        return try totals.reduce(into: [:]) { result, item in
            result[item.key] = try Money(item.value, currency: item.key)
        }
    }

    public static func displayBalance(
        for account: LedgerAccount,
        entries: [JournalEntry]
    ) throws -> Money? {
        guard let currency = account.currency else { return nil }
        let raw = try balances(for: account.id, entries: entries)[currency]
            ?? Money.zero(currency: currency)

        return account.kind == .liability ? raw.negated : raw
    }

    public static func spendingByCategory(
        accounts: [LedgerAccount],
        entries: [JournalEntry],
        currency: CurrencyCode,
        interval: DateInterval? = nil
    ) throws -> [UUID: Money] {
        let expenseAccountIDs = Set(
            accounts.lazy.filter { $0.kind == .expense }.map(\.id)
        )
        var totals: [UUID: Decimal] = [:]

        for entry in entries where FinancialPeriodBoundary.contains(
            entry.occurredAt,
            in: interval
        ) {
            for posting in entry.postings
            where expenseAccountIDs.contains(posting.accountID)
                && posting.money.currency == currency {
                totals[posting.accountID, default: .zero] += posting.money.amount
            }
        }

        return try totals.reduce(into: [:]) { result, item in
            result[item.key] = try Money(item.value, currency: currency)
        }
    }

    public static func total(
        for kind: LedgerAccountKind,
        accounts: [LedgerAccount],
        entries: [JournalEntry],
        currency: CurrencyCode,
        interval: DateInterval? = nil
    ) throws -> Money {
        let relevantAccountIDs = Set(
            accounts.lazy.filter { $0.kind == kind }.map(\.id)
        )
        var amount = Decimal.zero

        for entry in entries where FinancialPeriodBoundary.contains(
            entry.occurredAt,
            in: interval
        ) {
            for posting in entry.postings
            where relevantAccountIDs.contains(posting.accountID)
                && posting.money.currency == currency {
                amount += posting.money.amount
            }
        }

        if kind == .income {
            amount = -amount
        }
        return try Money(amount, currency: currency)
    }
}
