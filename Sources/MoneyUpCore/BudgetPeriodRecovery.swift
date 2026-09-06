import Foundation

/// Repairs the legacy profile-only time-zone change. No source zone is guessed:
/// every zone compatible with all stored month boundaries must agree on every
/// civil month used by the repair, including rollover activation and today.
public struct BudgetPeriodRecovery: Sendable {
    public let nodes: [BudgetNode]
    public let timeline: BudgetConfigurationTimeline

    public init(
        nodes: [BudgetNode], timeline: BudgetConfigurationTimeline,
        baseCurrency: CurrencyCode, asOf: Date, calendar: Calendar
    ) throws {
        guard calendar.identifier == .gregorian else {
            throw BudgetReportingConfigurationError.invalidCalendar
        }
        guard timeline.currency == baseCurrency else {
            throw BudgetReportingConfigurationError.currencyMismatch
        }
        let anchors = Set(timeline.revisions.map(\.effectiveMonth))
        let activations = Set((nodes + timeline.revisions.flatMap(\.nodes))
            .compactMap(\.rolloverStartedAt))
        let dates = anchors.union(activations).union([asOf]).sorted()
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw BudgetReportingConfigurationError.invalidMonthBoundary
        }

        var sourceCalendar: Calendar?
        var agreedMonths: [BudgetMonth]?
        // Filtering boundaries first keeps a large history from being rebuilt
        // once for every time-zone alias. Only the final candidate is rebuilt.
        for identifier in Set(TimeZone.knownTimeZoneIdentifiers + ["GMT", calendar.timeZone.identifier]).sorted() {
            let candidate = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: identifier)
            guard anchors.allSatisfy({
                candidate.dateInterval(of: .month, for: $0)?.start == $0
            }) else { continue }
            let months = try dates.map { try BudgetMonth(containing: $0, calendar: candidate) }
            if let agreedMonths, agreedMonths != months {
                throw BudgetReportingConfigurationError.invalidMonthBoundary
            }
            agreedMonths = months
            sourceCalendar = candidate
        }
        guard let sourceCalendar else {
            throw BudgetReportingConfigurationError.invalidMonthBoundary
        }
        let change = try BudgetReportingTimeZoneChange(
            nodes: nodes, timeline: timeline, baseCurrency: baseCurrency,
            asOf: asOf, oldCalendar: sourceCalendar, newCalendar: calendar
        )
        self.nodes = change.nodes
        self.timeline = change.timeline
    }
}

/// One bounded, encrypted original retained beside the live timeline. The flat
/// timeline fields let restore preflight apply the same history work limits.
public struct BudgetPeriodRecoveryOriginal: Codable, Equatable, Sendable {
    public static let recordID = "period-recovery-original-v1"
    public let currency: CurrencyCode
    public let revisions: [BudgetConfigurationRevision]
    public let originalNodes: [BudgetNode]
    public let reportingTimeZoneIdentifier: String

    public init(nodes: [BudgetNode], timeline: BudgetConfigurationTimeline, reportingTimeZoneIdentifier: String) {
        self.currency = timeline.currency
        self.revisions = timeline.revisions
        self.originalNodes = nodes
        self.reportingTimeZoneIdentifier = reportingTimeZoneIdentifier
    }

    public func validate() throws {
        guard originalNodes.count <= BudgetConfigurationTimeline.maximumNodesPerRevision,
              TimeZone(identifier: reportingTimeZoneIdentifier) != nil else {
            throw BudgetReportingConfigurationError.invalidCalendar
        }
        _ = try BudgetTree(currency: currency, nodes: originalNodes)
        _ = try BudgetConfigurationTimeline(currency: currency, revisions: revisions)
    }
}
