import Foundation

public enum BudgetReportingConfigurationError: Error, Equatable, Sendable {
    case currencyMismatch
    case invalidCalendar
    case invalidMonthBoundary
    case currentConfigurationMismatch
    case currentMonthWouldChange
}

extension BudgetNode {
    /// Labels and the storage order of unique monthly overrides do not change
    /// a budget's meaning. Every other stored field remains part of the check.
    public func matchesConfiguration(of other: BudgetNode) -> Bool {
        var left = self
        var right = other
        left.name = right.name
        let order: (MonthlyBudgetAllocation, MonthlyBudgetAllocation) -> Bool = {
            $0.month == $1.month ? $0.currency < $1.currency : $0.month < $1.month
        }
        left.monthlyAllocations.sort(by: order)
        right.monthlyAllocations.sort(by: order)
        return left == right
    }
}

extension BudgetConfigurationTimeline {
    public func validateCurrentConfiguration(
        nodes: [BudgetNode], baseCurrency: CurrencyCode,
        asOf: Date, calendar: Calendar
    ) throws {
        guard calendar.identifier == .gregorian else {
            throw BudgetReportingConfigurationError.invalidCalendar
        }
        _ = try BudgetMonth(containing: asOf, calendar: calendar)
        guard currency == baseCurrency else { throw BudgetReportingConfigurationError.currencyMismatch }
        for revision in revisions {
            guard revision.effectiveMonth.timeIntervalSinceReferenceDate.isFinite,
                  calendar.dateInterval(of: .month, for: revision.effectiveMonth)?.start
                    == revision.effectiveMonth else {
                throw BudgetReportingConfigurationError.invalidMonthBoundary
            }
        }
        // Validate before constructing dictionaries; malformed duplicate IDs
        // must produce an error, never a Dictionary precondition crash.
        let current = try BudgetTree(currency: baseCurrency, nodes: nodes)
        guard let month = calendar.dateInterval(of: .month, for: asOf)?.start else {
            throw BudgetReportingConfigurationError.invalidMonthBoundary
        }
        let historical = try tree(effectiveAt: month)
        let byID = Dictionary(uniqueKeysWithValues: historical.nodes.map { ($0.id, $0) })
        guard current.nodes.count == byID.count,
              current.nodes.allSatisfy({ node in
                  byID[node.id].map { node.matchesConfiguration(of: $0) } ?? false
              }) else {
            throw BudgetReportingConfigurationError.currentConfigurationMismatch
        }
    }
}

/// Reanchors reporting-month dates while preserving civil months, configured
/// money, carry checkpoints, merge mappings, revision IDs, and posting history.
public struct BudgetReportingTimeZoneChange: Sendable {
    public let nodes: [BudgetNode]
    public let timeline: BudgetConfigurationTimeline

    public init(
        nodes: [BudgetNode], timeline: BudgetConfigurationTimeline,
        baseCurrency: CurrencyCode, asOf: Date,
        oldCalendar: Calendar, newCalendar: Calendar
    ) throws {
        try timeline.validateCurrentConfiguration(
            nodes: nodes, baseCurrency: baseCurrency, asOf: asOf, calendar: oldCalendar
        )
        guard newCalendar.identifier == .gregorian else {
            throw BudgetReportingConfigurationError.invalidCalendar
        }
        guard try BudgetMonth(containing: asOf, calendar: oldCalendar)
            == BudgetMonth(containing: asOf, calendar: newCalendar) else {
            // Rewinding the live configuration into a different month needs
            // an explicit product policy; never silently reinterpret it.
            throw BudgetReportingConfigurationError.currentMonthWouldChange
        }
        func reanchor(_ date: Date) throws -> Date {
            let month = try BudgetMonth(containing: date, calendar: oldCalendar)
            guard let middle = newCalendar.date(from: DateComponents(
                year: month.year, month: month.month, day: 15, hour: 12
            )), let start = newCalendar.dateInterval(of: .month, for: middle)?.start,
                  try BudgetMonth(containing: start, calendar: newCalendar) == month else {
                throw BudgetReportingConfigurationError.invalidMonthBoundary
            }
            return start
        }
        func reanchorNodes(_ source: [BudgetNode]) throws -> [BudgetNode] {
            try source.map { original in
                var node = original
                if let activation = node.rolloverStartedAt {
                    node.rolloverStartedAt = try reanchor(activation)
                }
                return node
            }
        }
        self.nodes = try reanchorNodes(nodes)
        self.timeline = try BudgetConfigurationTimeline(
            currency: timeline.currency,
            revisions: timeline.revisions.map { revision in
                BudgetConfigurationRevision(
                    id: revision.id,
                    effectiveMonth: try reanchor(revision.effectiveMonth),
                    nodes: try reanchorNodes(revision.nodes),
                    carryMappings: revision.carryMappings,
                    openingCarry: revision.openingCarryByID
                )
            }
        )
        try self.timeline.validateCurrentConfiguration(
            nodes: self.nodes, baseCurrency: baseCurrency, asOf: asOf, calendar: newCalendar
        )
    }
}
