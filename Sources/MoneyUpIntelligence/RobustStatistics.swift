import Foundation
import MoneyUpCore

enum RobustStatistics {
    static func median(_ values: [Decimal]) throws -> Decimal {
        guard !values.isEmpty else { throw IntelligenceInputError.insufficientSamples }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if !ordered.count.isMultiple(of: 2) { return ordered[middle] }
        let sum = try CheckedDecimal.adding(ordered[middle - 1], ordered[middle])
        return try CheckedDecimal.dividing(sum, Decimal(2))
    }

    static func median(_ values: [Int]) throws -> Int {
        guard !values.isEmpty else { throw IntelligenceInputError.insufficientSamples }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if !ordered.count.isMultiple(of: 2) { return ordered[middle] }
        return (ordered[middle - 1] + ordered[middle]) / 2
    }

    static func medianAbsoluteDeviation(
        _ values: [Decimal],
        median: Decimal
    ) throws -> Decimal {
        try self.median(values.map { magnitude($0 - median) })
    }

    static func medianAbsoluteDeviation(
        _ values: [Int],
        median: Int
    ) throws -> Int {
        try self.median(values.map { abs($0 - median) })
    }

    static func sum(_ values: [Decimal]) throws -> Decimal {
        try values.reduce(.zero) { partial, value in
            try CheckedDecimal.adding(partial, value)
        }
    }

    static func magnitude(_ value: Decimal) -> Decimal {
        value < .zero ? -value : value
    }

    static func minorUnit(for currency: CurrencyCode) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<currency.minorUnits { result /= 10 }
        return result
    }
}
