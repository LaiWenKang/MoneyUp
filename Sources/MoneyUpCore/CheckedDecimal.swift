import Foundation

/// Failures reported by Foundation's decimal calculation primitives.
///
/// Exact financial arithmetic rejects every non-success status. Presentation
/// ratios and values that are immediately rounded to a currency's minor units
/// may opt in to accepting only `lossOfPrecision`.
public enum DecimalCalculationError: Error, Equatable, Sendable {
    case overflow
    case underflow
    case divideByZero
    case lossOfPrecision
    case invalidResult
}

public enum CheckedDecimal {
    public static func adding(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        try calculate(lhs, rhs, operation: NSDecimalAdd)
    }

    /// Immutable values that were already validated may need to reproduce a
    /// diagnostic total even when their caller's task has since been cancelled.
    /// The Decimal status policy remains identical to `adding`.
    static func addingUninterruptibly(
        _ lhs: Decimal,
        _ rhs: Decimal
    ) throws -> Decimal {
        try calculate(
            lhs,
            rhs,
            checkingCancellation: false,
            operation: NSDecimalAdd
        )
    }

    public static func subtracting(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        try calculate(lhs, rhs, operation: NSDecimalSubtract)
    }

    public static func multiplying(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        try calculate(lhs, rhs, operation: NSDecimalMultiply)
    }

    public static func dividing(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        try calculate(lhs, rhs, operation: NSDecimalDivide)
    }

    /// A display-only quotient. Repeating decimals are useful for percentages,
    /// but overflow, underflow, division by zero, and invalid results are not.
    public static func ratio(_ numerator: Decimal, _ denominator: Decimal) throws -> Decimal {
        try calculate(
            numerator,
            denominator,
            allowingLossOfPrecision: true,
            operation: NSDecimalDivide
        )
    }

    /// Multiplies at Decimal's full precision and rounds exactly once to the
    /// destination currency. This is suitable for conversions and unit prices.
    public static func productForCurrencyRounding(
        _ lhs: Decimal,
        _ rhs: Decimal,
        currency: CurrencyCode
    ) throws -> Decimal {
        let raw = try calculate(
            lhs,
            rhs,
            allowingLossOfPrecision: true,
            operation: NSDecimalMultiply
        )
        return try roundedForCurrency(raw, currency: currency)
    }

    /// Divides at Decimal's full precision and rounds exactly once to the
    /// destination currency. Repeating quotients are expected before rounding.
    public static func divideForCurrencyRounding(
        _ numerator: Decimal,
        _ denominator: Decimal,
        currency: CurrencyCode
    ) throws -> Decimal {
        let raw = try calculate(
            numerator,
            denominator,
            allowingLossOfPrecision: true,
            operation: NSDecimalDivide
        )
        return try roundedForCurrency(raw, currency: currency)
    }

    private static func roundedForCurrency(
        _ amount: Decimal,
        currency: CurrencyCode
    ) throws -> Decimal {
        try Task.checkCancellation()
        let rounded = currency.rounded(amount)
        guard !rounded.isNaN else { throw DecimalCalculationError.invalidResult }
        return rounded
    }

    private static func calculate(
        _ lhs: Decimal,
        _ rhs: Decimal,
        allowingLossOfPrecision: Bool = false,
        checkingCancellation: Bool = true,
        operation: (
            UnsafeMutablePointer<Decimal>,
            UnsafePointer<Decimal>,
            UnsafePointer<Decimal>,
            Decimal.RoundingMode
        ) -> Decimal.CalculationError
    ) throws -> Decimal {
        if checkingCancellation {
            try Task.checkCancellation()
        }
        guard !lhs.isNaN, !rhs.isNaN else {
            throw DecimalCalculationError.invalidResult
        }

        var left = lhs
        var right = rhs
        var result = Decimal.zero
        let status = operation(&result, &left, &right, .plain)

        switch status {
        case .noError:
            break
        case .lossOfPrecision where allowingLossOfPrecision:
            break
        case .lossOfPrecision:
            throw DecimalCalculationError.lossOfPrecision
        case .overflow:
            throw DecimalCalculationError.overflow
        case .underflow:
            throw DecimalCalculationError.underflow
        case .divideByZero:
            throw DecimalCalculationError.divideByZero
        @unknown default:
            throw DecimalCalculationError.invalidResult
        }

        guard !result.isNaN else { throw DecimalCalculationError.invalidResult }
        return result
    }
}
