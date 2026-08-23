import Foundation

public enum TransactionFactoryError: Error, Equatable, Sendable {
    case amountMustBePositive
    case accountsMustDiffer
}

/// Creates balanced journal entries for common consumer actions while keeping
/// accounting details out of the UI layer.
public enum TransactionFactory {
    public static func expense(
        amount: Money,
        paidFrom accountID: UUID,
        category categoryAccountID: UUID,
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        return try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: [
                Posting(accountID: categoryAccountID, money: amount),
                Posting(accountID: accountID, money: amount.negated)
            ]
        )
    }

    public static func income(
        amount: Money,
        depositedInto accountID: UUID,
        category categoryAccountID: UUID,
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        return try JournalEntry(
            kind: .income,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: [
                Posting(accountID: accountID, money: amount),
                Posting(accountID: categoryAccountID, money: amount.negated)
            ]
        )
    }

    public static func transfer(
        amount: Money,
        from sourceAccountID: UUID,
        to destinationAccountID: UUID,
        occurredAt: Date = Date(),
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        guard sourceAccountID != destinationAccountID else {
            throw TransactionFactoryError.accountsMustDiffer
        }

        return try JournalEntry(
            kind: .transfer,
            occurredAt: occurredAt,
            note: normalized(note),
            postings: [
                Posting(accountID: sourceAccountID, money: amount.negated),
                Posting(accountID: destinationAccountID, money: amount)
            ]
        )
    }

    public static func foreignCurrencyTransfer(
        sourceAmount: Money,
        destinationAmount: Money,
        from sourceAccountID: UUID,
        to destinationAccountID: UUID,
        sourceTradingAccountID: UUID,
        destinationTradingAccountID: UUID,
        occurredAt: Date = Date(),
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(sourceAmount)
        try requirePositive(destinationAmount)
        guard sourceAccountID != destinationAccountID else {
            throw TransactionFactoryError.accountsMustDiffer
        }

        return try JournalEntry(
            kind: .transfer,
            occurredAt: occurredAt,
            note: normalized(note),
            postings: [
                Posting(accountID: sourceAccountID, money: sourceAmount.negated),
                Posting(accountID: sourceTradingAccountID, money: sourceAmount),
                Posting(
                    accountID: destinationTradingAccountID,
                    money: destinationAmount.negated
                ),
                Posting(accountID: destinationAccountID, money: destinationAmount)
            ]
        )
    }

    public static func refund(
        amount: Money,
        returnedTo accountID: UUID,
        category categoryAccountID: UUID,
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        return try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: [
                Posting(accountID: categoryAccountID, money: amount.negated),
                Posting(accountID: accountID, money: amount)
            ]
        )
    }

    private static func requirePositive(_ money: Money) throws {
        guard money.amount > .zero else {
            throw TransactionFactoryError.amountMustBePositive
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
