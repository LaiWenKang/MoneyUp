import Foundation

public enum CurrencyCodeError: Error, Equatable {
    case invalid(String)
}

/// A normalized currency or asset code.
///
/// ISO 4217 fiat codes contain three letters, while commonly used digital
/// asset codes may be longer. MoneyUp therefore accepts three to eight ASCII
/// letters or digits and stores the normalized uppercase representation.
public struct CurrencyCode: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let value: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let bytes = normalized.utf8
        let containsOnlySupportedCharacters = bytes.allSatisfy { byte in
            (65...90).contains(byte) || (48...57).contains(byte)
        }

        guard (3...8).contains(bytes.count), containsOnlySupportedCharacters else {
            throw CurrencyCodeError.invalid(rawValue)
        }

        value = normalized
    }

    public var description: String { value }

    /// ISO 4217 minor units for currencies whose scale differs from the common
    /// two-decimal convention, plus explicit digital-asset display scales.
    /// Unknown private or future codes remain usable and conservatively use 2.
    public var minorUnits: Int {
        switch value {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW",
             "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF":
            0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND":
            3
        case "CLF", "UYW":
            4
        case "BTC":
            8
        case "ETH":
            8
        default:
            2
        }
    }

    public func supports(_ amount: Decimal) -> Bool {
        rounded(amount) == amount
    }

    public func rounded(_ amount: Decimal) -> Decimal {
        var source = amount
        var result = Decimal.zero
        NSDecimalRound(&result, &source, minorUnits, .bankers)
        return result
    }

    public static func < (lhs: CurrencyCode, rhs: CurrencyCode) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid currency or asset code: \(rawValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
