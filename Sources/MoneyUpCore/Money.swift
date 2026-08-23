import Foundation

public enum MoneyError: Error, Equatable {
    case notANumber
    case currencyMismatch(expected: CurrencyCode, actual: CurrencyCode)
}

/// A decimal amount paired with an explicit currency or asset code.
///
/// Financial values must never be represented by binary floating-point types
/// such as `Double`. `Decimal` avoids the common representation drift that
/// would otherwise corrupt ledger and budget totals.
public struct Money: Codable, Equatable {
    public let amount: Decimal
    public let currency: CurrencyCode

    public init(_ amount: Decimal, currency: CurrencyCode) throws {
        guard !amount.isNaN else {
            throw MoneyError.notANumber
        }

        self.amount = amount
        self.currency = currency
    }

    private init(validatedAmount: Decimal, currency: CurrencyCode) {
        amount = validatedAmount
        self.currency = currency
    }

    public static func zero(currency: CurrencyCode) -> Money {
        Money(validatedAmount: .zero, currency: currency)
    }

    public var isZero: Bool { amount == .zero }

    public var negated: Money {
        Money(validatedAmount: -amount, currency: currency)
    }

    public func adding(_ other: Money) throws -> Money {
        try requireSameCurrency(as: other)
        return try Money(amount + other.amount, currency: currency)
    }

    public func subtracting(_ other: Money) throws -> Money {
        try requireSameCurrency(as: other)
        return try Money(amount - other.amount, currency: currency)
    }

    private func requireSameCurrency(as other: Money) throws {
        guard currency == other.currency else {
            throw MoneyError.currencyMismatch(
                expected: currency,
                actual: other.currency
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case amount
        case currency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let amount = try container.decode(Decimal.self, forKey: .amount)
        let currency = try container.decode(CurrencyCode.self, forKey: .currency)

        do {
            try self.init(amount, currency: currency)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Money amount must be a valid decimal number."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(currency, forKey: .currency)
    }
}
