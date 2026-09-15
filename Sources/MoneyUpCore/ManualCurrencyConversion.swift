import Foundation

public enum ManualCurrencyConversion {
    /// By default a rate means destination units per one source unit; inverse
    /// input means source units per destination unit. Round once,
    /// at the destination's minor-unit boundary, using the shared money policy.
    public static func convert(source: Money, to destination: CurrencyCode,
                               rate: Decimal, inverse: Bool = false) throws -> Money {
        guard source.currency != destination else { throw ExchangeRateError.identicalCurrencies }
        guard rate > .zero, !rate.isNaN else { throw ExchangeRateError.invalidRate }
        guard source.amount > .zero else { throw ExchangeRateError.conversionUnderflow }
        let amount: Decimal
        do {
            amount = inverse
                ? try CheckedDecimal.divideForCurrencyRounding(source.amount, rate, currency: destination)
                : try CheckedDecimal.productForCurrencyRounding(source.amount, rate, currency: destination)
            try MonetaryInputPolicy.validate(amount, currency: destination)
        } catch { throw ExchangeRateError.conversionOutOfRange }
        guard amount > .zero else { throw ExchangeRateError.conversionUnderflow }
        return try Money(amount, currency: destination)
    }
}
