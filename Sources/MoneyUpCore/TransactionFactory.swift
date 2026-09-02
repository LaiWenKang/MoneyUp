import Foundation

public enum TransactionFactoryError: Error, Equatable, Sendable {
    case amountMustBePositive
    case amountMustBeNonZero
    case accountsMustDiffer
    case arithmeticOverflow
    case loanCurrencyMismatch
    case invalidLoanPayment
}

/// Creates balanced journal entries for common consumer actions while keeping
/// accounting details out of the UI layer.
public enum TransactionFactory {
    public static let loanDrawdownSource = "moneyup.loan.drawdown"
    public static let loanPaymentSource = "moneyup.loan.payment"

    public static func splitExpense(
        amount: Money,
        paidFrom accountID: UUID,
        splits: [TransactionSplitLine],
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        try TransactionSplitCalculator.validate(total: amount, lines: splits)
        return try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: splits.map {
                Posting(
                    id: $0.id,
                    accountID: $0.categoryAccountID,
                    money: $0.amount,
                    memo: $0.memo
                )
            } + [Posting(accountID: accountID, money: amount.negated)]
        )
    }

    public static func splitIncome(
        amount: Money,
        depositedInto accountID: UUID,
        splits: [TransactionSplitLine],
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        try TransactionSplitCalculator.validate(total: amount, lines: splits)
        return try JournalEntry(
            kind: .income,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: [Posting(accountID: accountID, money: amount)] + splits.map {
                Posting(
                    id: $0.id,
                    accountID: $0.categoryAccountID,
                    money: $0.amount.negated,
                    memo: $0.memo
                )
            }
        )
    }

    public static func splitRefund(
        amount: Money,
        returnedTo accountID: UUID,
        splits: [TransactionSplitLine],
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        try TransactionSplitCalculator.validate(total: amount, lines: splits)
        return try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: splits.map {
                Posting(
                    id: $0.id,
                    accountID: $0.categoryAccountID,
                    money: $0.amount.negated,
                    memo: $0.memo
                )
            } + [Posting(accountID: accountID, money: amount)]
        )
    }

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
        payee: String? = nil,
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        guard sourceAccountID != destinationAccountID else {
            throw TransactionFactoryError.accountsMustDiffer
        }

        return try JournalEntry(
            kind: .transfer,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: [
                Posting(accountID: sourceAccountID, money: amount.negated),
                Posting(accountID: destinationAccountID, money: amount)
            ]
        )
    }

    /// Advances additional principal from a liability into a cash account.
    /// This is debt, never income.
    public static func loanDrawdown(
        amount: Money,
        loanAccountID: UUID,
        depositedInto cashAccountID: UUID,
        occurredAt: Date = Date(),
        note: String? = nil
    ) throws -> JournalEntry {
        try requirePositive(amount)
        guard loanAccountID != cashAccountID else {
            throw TransactionFactoryError.accountsMustDiffer
        }
        return try JournalEntry(
            kind: .transfer,
            occurredAt: occurredAt,
            payee: nil,
            note: normalized(note),
            postings: [
                Posting(accountID: loanAccountID, money: amount.negated),
                Posting(accountID: cashAccountID, money: amount)
            ],
            sourceSystem: loanDrawdownSource
        )
    }

    /// Posts one loan installment atomically. Principal reduces the liability;
    /// interest and fees are ordinary expenses, and the cash side equals their
    /// exact sum.
    public static func loanPayment(
        principal: Money,
        interest: Money,
        fees: Money,
        paidFrom cashAccountID: UUID,
        loanAccountID: UUID,
        interestCategoryID: UUID?,
        feeCategoryID: UUID?,
        occurredAt: Date = Date(),
        note: String? = nil
    ) throws -> JournalEntry {
        guard principal.currency == interest.currency,
              principal.currency == fees.currency else {
            throw TransactionFactoryError.loanCurrencyMismatch
        }
        guard principal.amount >= .zero,
              interest.amount >= .zero,
              fees.amount >= .zero,
              principal.amount > .zero || interest.amount > .zero || fees.amount > .zero,
              cashAccountID != loanAccountID,
              interest.isZero || interestCategoryID != nil,
              fees.isZero || feeCategoryID != nil else {
            throw TransactionFactoryError.invalidLoanPayment
        }
        let total: Decimal
        do {
            total = try CheckedDecimal.adding(
                try CheckedDecimal.adding(principal.amount, interest.amount),
                fees.amount
            )
        } catch {
            throw TransactionFactoryError.arithmeticOverflow
        }
        let payment = try Money(total, currency: principal.currency)
        var postings = [
            Posting(accountID: cashAccountID, money: payment.negated)
        ]
        if !principal.isZero {
            postings.append(Posting(accountID: loanAccountID, money: principal))
        }
        if !interest.isZero, let interestCategoryID {
            postings.append(Posting(accountID: interestCategoryID, money: interest))
        }
        if !fees.isZero, let feeCategoryID {
            postings.append(Posting(accountID: feeCategoryID, money: fees))
        }
        return try JournalEntry(
            kind: .transfer,
            occurredAt: occurredAt,
            payee: nil,
            note: normalized(note),
            postings: postings,
            sourceSystem: loanPaymentSource
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
        payee: String? = nil,
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
            payee: normalized(payee),
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

    /// Records an opening balance or later reconciliation without treating it
    /// as income or spending. `displayBalanceDelta` uses the user-facing sign:
    /// positive increases cash and also increases debt for liability accounts.
    public static func balanceAdjustment(
        displayBalanceDelta: Money,
        accountID: UUID,
        equityAccountID: UUID,
        accountIsLiability: Bool,
        occurredAt: Date = Date(),
        note: String? = nil,
        id: UUID = UUID(),
        originContext: TransactionOriginContext? = nil
    ) throws -> JournalEntry {
        guard !displayBalanceDelta.isZero else {
            throw TransactionFactoryError.amountMustBeNonZero
        }
        let ledgerDelta = accountIsLiability
            ? displayBalanceDelta.negated
            : displayBalanceDelta

        return try JournalEntry(
            id: id,
            kind: .adjustment,
            occurredAt: occurredAt,
            note: normalized(note),
            postings: [
                Posting(accountID: accountID, money: ledgerDelta),
                Posting(accountID: equityAccountID, money: ledgerDelta.negated)
            ],
            originContext: originContext
        )
    }

    /// Moves cash into a position and optionally revalues units already held.
    /// The gain/loss counter posting keeps the event balanced without counting
    /// the purchase as spending or ordinary income.
    public static func investmentPurchase(
        cashCost: Money,
        resultingPositionValue: Money,
        previousPositionValue: Money,
        cashAccountID: UUID,
        positionAccountID: UUID,
        gainLossAccountID: UUID,
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil,
        id: UUID = UUID(),
        originContext: TransactionOriginContext? = nil
    ) throws -> JournalEntry {
        try requirePositive(cashCost)
        guard cashCost.currency == resultingPositionValue.currency,
              cashCost.currency == previousPositionValue.currency else {
            throw MoneyError.currencyMismatch(
                expected: cashCost.currency,
                actual: resultingPositionValue.currency
            )
        }
        let positionDelta = try checkedDifference(
            resultingPositionValue.amount,
            previousPositionValue.amount
        )
        let residual = try checkedDifference(cashCost.amount, positionDelta)
        var postings = [
            Posting(accountID: cashAccountID, money: cashCost.negated)
        ]
        if positionDelta != .zero {
            postings.append(Posting(
                accountID: positionAccountID,
                money: try Money(positionDelta, currency: cashCost.currency)
            ))
        }
        if residual != .zero {
            postings.append(Posting(
                accountID: gainLossAccountID,
                money: try Money(residual, currency: cashCost.currency)
            ))
        }
        return try JournalEntry(
            id: id,
            kind: .investment,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: postings,
            originContext: originContext
        )
    }

    /// Opens an already-owned position against equity when the brokerage cash
    /// balance supplied by the user already excludes that position. It is an
    /// investment event (not a generic reconciliation), so holding metadata can
    /// retain and validate the journal relationship explicitly.
    public static func investmentOpening(
        positionValue: Money,
        positionAccountID: UUID,
        equityAccountID: UUID,
        occurredAt: Date = Date(),
        note: String? = nil,
        id: UUID = UUID(),
        originContext: TransactionOriginContext? = nil
    ) throws -> JournalEntry {
        try requirePositive(positionValue)
        return try JournalEntry(
            id: id,
            kind: .investment,
            occurredAt: occurredAt,
            note: normalized(note),
            postings: [
                Posting(accountID: positionAccountID, money: positionValue),
                Posting(accountID: equityAccountID, money: positionValue.negated)
            ],
            originContext: originContext
        )
    }

    /// Records sale proceeds and resets the remaining position to the supplied
    /// market value. FIFO realized gain/loss remains separate metadata on the
    /// holding; this ledger counter includes any simultaneous unrealized reset.
    public static func investmentSale(
        proceeds: Money,
        resultingPositionValue: Money,
        previousPositionValue: Money,
        cashAccountID: UUID,
        positionAccountID: UUID,
        gainLossAccountID: UUID,
        occurredAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil,
        id: UUID = UUID(),
        originContext: TransactionOriginContext? = nil
    ) throws -> JournalEntry {
        try requirePositive(proceeds)
        guard proceeds.currency == resultingPositionValue.currency,
              proceeds.currency == previousPositionValue.currency else {
            throw MoneyError.currencyMismatch(
                expected: proceeds.currency,
                actual: resultingPositionValue.currency
            )
        }
        let positionDelta = try checkedDifference(
            resultingPositionValue.amount,
            previousPositionValue.amount
        )
        let proceedsAndPosition = try checkedSum(proceeds.amount, positionDelta)
        let counter = try checkedDifference(.zero, proceedsAndPosition)
        var postings = [Posting(accountID: cashAccountID, money: proceeds)]
        if positionDelta != .zero {
            postings.append(Posting(
                accountID: positionAccountID,
                money: try Money(positionDelta, currency: proceeds.currency)
            ))
        }
        if counter != .zero {
            postings.append(Posting(
                accountID: gainLossAccountID,
                money: try Money(counter, currency: proceeds.currency)
            ))
        }
        return try JournalEntry(
            id: id,
            kind: .investment,
            occurredAt: occurredAt,
            payee: normalized(payee),
            note: normalized(note),
            postings: postings,
            originContext: originContext
        )
    }

    public static func investmentValuation(
        delta: Money,
        positionAccountID: UUID,
        gainLossAccountID: UUID,
        occurredAt: Date,
        note: String? = nil,
        id: UUID = UUID(),
        originContext: TransactionOriginContext? = nil
    ) throws -> JournalEntry {
        guard !delta.isZero else { throw TransactionFactoryError.amountMustBeNonZero }
        return try JournalEntry(
            id: id,
            kind: .investment,
            occurredAt: occurredAt,
            note: normalized(note),
            postings: [
                Posting(accountID: positionAccountID, money: delta),
                Posting(accountID: gainLossAccountID, money: delta.negated)
            ],
            originContext: originContext
        )
    }

    private static func checkedSum(_ left: Decimal, _ right: Decimal) throws -> Decimal {
        var lhs = left
        var rhs = right
        var result = Decimal.zero
        let error = NSDecimalAdd(&result, &lhs, &rhs, .bankers)
        guard error == .noError, !result.isNaN else {
            throw TransactionFactoryError.arithmeticOverflow
        }
        return result
    }

    private static func checkedDifference(
        _ left: Decimal,
        _ right: Decimal
    ) throws -> Decimal {
        var lhs = left
        var rhs = right
        var result = Decimal.zero
        let error = NSDecimalSubtract(&result, &lhs, &rhs, .bankers)
        guard error == .noError, !result.isNaN else {
            throw TransactionFactoryError.arithmeticOverflow
        }
        return result
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
