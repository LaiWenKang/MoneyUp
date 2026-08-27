import Foundation

/// A conservative boundary for user-authored monetary values.
///
/// `Decimal` carries 38 significant decimal digits. MoneyUp supports currency
/// scales through eight minor units, so this 15-whole-digit ceiling contains at
/// most 23 significant digits. Summing 20,000 maximum values uses at most 28,
/// leaving ten digits of headroom for exact ledger aggregation while still
/// supporting ordinary high-denomination VND and IDR balances.
///
/// This bound does not make arbitrary multiplication safe. Quantity-by-price
/// and amount-by-rate calculations must validate their independent operands
/// and checked result in the owning investment or foreign-exchange domain.
///
/// This policy applies only when creating or changing a monetary value. The
/// normal `Money` initializer and decoder deliberately remain permissive so an
/// upgrade can read and preserve older values byte-for-byte.
public enum MonetaryInputPolicy: Sendable {
    public static let maximumAbsoluteNewWrite: Decimal = 999_999_999_999_999
    public static let aggregateRecordBudget = 20_000

    public static func validate(
        _ amount: Decimal,
        currency: CurrencyCode,
        preserving legacyAmount: Decimal? = nil
    ) throws {
        if let legacyAmount, legacyAmount == amount { return }
        guard !amount.isNaN else { throw MoneyError.notANumber }
        guard abs(amount) <= maximumAbsoluteNewWrite else {
            throw MoneyError.exceedsNewWriteMaximum(
                maximum: maximumAbsoluteNewWrite
            )
        }
        guard currency.supports(amount) else {
            throw MoneyError.unsupportedPrecision(currency: currency)
        }
    }

    public static func accepts(
        _ amount: Decimal,
        currency: CurrencyCode
    ) -> Bool {
        (try? validate(amount, currency: currency)) != nil
    }
}

public extension Money {
    /// Creates a value after applying the current new-write policy.
    static func newWrite(
        _ amount: Decimal,
        currency: CurrencyCode,
        preserving legacyAmount: Decimal? = nil
    ) throws -> Money {
        try MonetaryInputPolicy.validate(
            amount,
            currency: currency,
            preserving: legacyAmount
        )
        return try Money(amount, currency: currency)
    }
}
