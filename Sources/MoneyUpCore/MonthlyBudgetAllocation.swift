import Foundation

public enum MonthlyBudgetError: Error, Equatable {
    case invalidMonth
    case duplicateAllocation
    case invalidAllocation
    case tooManyAllocations
}

/// A civil reporting month, independent of device travel or UTC offsets.
public struct BudgetMonth: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) throws {
        guard (1...9999).contains(year), (1...12).contains(month) else {
            throw MonthlyBudgetError.invalidMonth
        }
        self.year = year
        self.month = month
    }

    public init(containing date: Date, calendar: Calendar) throws {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else {
            throw MonthlyBudgetError.invalidMonth
        }
        try self.init(year: year, month: month)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    private enum CodingKeys: String, CodingKey { case year, month }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: values.decode(Int.self, forKey: .year),
            month: values.decode(Int.self, forKey: .month)
        )
    }
}

/// One explicit monthly override. A nil limit intentionally removes that
/// month's allocation; absence of a record retains the legacy recurring plan.
public struct MonthlyBudgetAllocation: Codable, Equatable, Sendable {
    public let month: BudgetMonth
    public let currency: CurrencyCode
    public let limit: Money?
    public let mode: BudgetAllocationMode
    public let purpose: BudgetPurpose

    public init(
        month: BudgetMonth,
        currency: CurrencyCode,
        limit: Money?,
        mode: BudgetAllocationMode = .automatic,
        purpose: BudgetPurpose = .unclassified
    ) throws {
        if let limit {
            guard limit.currency == currency, limit.amount >= .zero,
                  !limit.amount.isNaN else { throw MonthlyBudgetError.invalidAllocation }
        }
        self.month = month
        self.currency = currency
        self.limit = limit
        self.mode = mode
        self.purpose = purpose
    }

    private enum CodingKeys: String, CodingKey { case month, currency, limit, mode, purpose }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            month: values.decode(BudgetMonth.self, forKey: .month),
            currency: values.decode(CurrencyCode.self, forKey: .currency),
            limit: values.decodeIfPresent(Money.self, forKey: .limit),
            mode: values.decode(BudgetAllocationMode.self, forKey: .mode),
            purpose: values.decode(BudgetPurpose.self, forKey: .purpose)
        )
    }
}

extension BudgetNode {
    public func resolved(for month: BudgetMonth, currency: CurrencyCode) -> BudgetNode {
        var result = self
        if let allocation = monthlyAllocations.first(where: {
            $0.month == month && $0.currency == currency
        }) {
            result.limit = allocation.limit
            result.allocationMode = allocation.mode
            result.purpose = allocation.purpose
        } else if limit?.currency != currency {
            result.limit = nil
        }
        // Rollover is the existing recurring allocation's same-currency policy.
        // A foreign monthly allocation does not inherit a base-currency carry.
        if limit?.currency != currency || result.limit == nil {
            result.rolloverRule = .none
            result.rolloverStartedAt = nil
        }
        return result
    }

    public mutating func setMonthlyAllocation(_ allocation: MonthlyBudgetAllocation) throws {
        var candidate = self
        candidate.monthlyAllocations.removeAll {
            $0.month == allocation.month && $0.currency == allocation.currency
        }
        candidate.monthlyAllocations.append(allocation)
        candidate.monthlyAllocations.sort {
            $0.month == $1.month ? $0.currency < $1.currency : $0.month < $1.month
        }
        try candidate.validateMonthlyAllocations()
        self = candidate
    }

    func validateMonthlyAllocations() throws {
        guard monthlyAllocations.count <= 1_200 else {
            throw MonthlyBudgetError.tooManyAllocations
        }
        var seen: [BudgetMonth: Set<CurrencyCode>] = [:]
        for item in monthlyAllocations {
            guard seen[item.month, default: []].insert(item.currency).inserted else {
                throw MonthlyBudgetError.duplicateAllocation
            }
        }
    }
}
