import Foundation
import MoneyUpCore
import XCTest

final class BudgetReportingConfigurationTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: zone)
    }

    private func date(_ month: Int, day: Int = 1, zone: String = "Asia/Singapore") throws -> Date {
        try XCTUnwrap(calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day)))
    }

    func testNamesAndOverrideOrderDoNotChangeConfigurationButFinancialFieldsDo() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let month = try BudgetMonth(year: 2026, month: 9)
        let allocations = try [
            MonthlyBudgetAllocation(month: month, currency: sgd, limit: Money(120, currency: sgd)),
            MonthlyBudgetAllocation(month: month, currency: usd, limit: Money(30, currency: usd))
        ]
        let original = BudgetNode(name: "Old name", limit: try Money(100, currency: sgd), monthlyAllocations: allocations)
        var renamed = original
        renamed.name = "New name"
        renamed.monthlyAllocations.reverse()
        XCTAssertTrue(original.matchesConfiguration(of: renamed))
        XCTAssertNotEqual(original, renamed)
        var changes: [BudgetNode] = []
        var changed = renamed; changed.limit = try Money(101, currency: sgd); changes.append(changed)
        changed = renamed; changed.parentID = UUID(); changes.append(changed)
        changed = renamed; changed.allocationMode = .automatic; changes.append(changed)
        changed = renamed; changed.purpose = .flexible; changes.append(changed)
        changed = renamed; changed.pacingCadence = .daily; changes.append(changed)
        changed = renamed; changed.rolloverRule = .fullBalance; changes.append(changed)
        changed = renamed; changed.rolloverStartedAt = try date(8); changes.append(changed)
        changed = renamed; changed.monthlyAllocations.removeLast(); changes.append(changed)
        for candidate in changes { XCTAssertFalse(original.matchesConfiguration(of: candidate)) }
    }

    func testTimelineAcceptsRenamingButRejectsMissingDuplicateOrChangedAllocations() throws {
        let sgd = try CurrencyCode("SGD")
        let old = BudgetNode(name: "Before", limit: try Money(100, currency: sgd))
        var renamed = old; renamed.name = "After"
        let timeline = try BudgetConfigurationTimeline(currency: sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(9), nodes: [old])
        ])
        try timeline.validateCurrentConfiguration(nodes: [renamed], baseCurrency: sgd,
            asOf: date(9, day: 6), calendar: calendar("Asia/Singapore"))
        for nodes in [[], [renamed, renamed]] {
            XCTAssertThrowsError(try timeline.validateCurrentConfiguration(nodes: nodes, baseCurrency: sgd,
                asOf: date(9, day: 6), calendar: calendar("Asia/Singapore")))
        }
        renamed.limit = try Money(101, currency: sgd)
        XCTAssertThrowsError(try timeline.validateCurrentConfiguration(nodes: [renamed], baseCurrency: sgd,
            asOf: date(9, day: 6), calendar: calendar("Asia/Singapore"))) {
            XCTAssertEqual($0 as? BudgetReportingConfigurationError, .currentConfigurationMismatch)
        }
    }

    func testTimeZoneChangePreservesCivilMonthsSignedCarryIDsAndMonthlyCurrencies() throws {
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        for (oldZone, newZone) in [
            ("Asia/Singapore", "GMT"), ("GMT", "Asia/Singapore"),
            ("America/New_York", "Europe/London"), ("Pacific/Kiritimati", "America/Los_Angeles")
        ] {
            let oldCalendar = calendar(oldZone), newCalendar = calendar(newZone)
            let now = try date(9, day: 6, zone: oldZone)
            let node = BudgetNode(name: "Category", limit: try Money(100, currency: sgd),
                rolloverRule: .fullBalance, rolloverStartedAt: try date(1, zone: oldZone),
                monthlyAllocations: [try MonthlyBudgetAllocation(
                    month: BudgetMonth(year: 2026, month: 9), currency: usd, limit: Money(30, currency: usd))])
            let sourceID = UUID()
            let timeline = try BudgetConfigurationTimeline(currency: sgd, revisions: [
                BudgetConfigurationRevision(effectiveMonth: date(1, zone: oldZone), nodes: [node]),
                BudgetConfigurationRevision(effectiveMonth: date(9, zone: oldZone), nodes: [node],
                    carryMappings: [BudgetCarryMapping(sourceID: sourceID, targetID: node.id)],
                    openingCarry: [sourceID: Money(-30, currency: sgd)])
            ])
            let change = try BudgetReportingTimeZoneChange(nodes: [node], timeline: timeline,
                baseCurrency: sgd, asOf: now, oldCalendar: oldCalendar, newCalendar: newCalendar)
            XCTAssertEqual(change.nodes[0].monthlyAllocations, node.monthlyAllocations)
            for (before, after) in zip(timeline.revisions, change.timeline.revisions) {
                XCTAssertEqual(before.id, after.id)
                XCTAssertEqual(before.openingCarry, after.openingCarry)
                XCTAssertEqual(before.carryMappings, after.carryMappings)
                XCTAssertEqual(try BudgetMonth(containing: before.effectiveMonth, calendar: oldCalendar),
                               try BudgetMonth(containing: after.effectiveMonth, calendar: newCalendar))
            }
            let before = try BudgetRolloverEngine.snapshot(timeline: timeline, monthlySpending: [], asOf: now, calendar: oldCalendar)
            let after = try BudgetRolloverEngine.snapshot(timeline: change.timeline, monthlySpending: [], asOf: now, calendar: newCalendar)
            XCTAssertEqual(before.effectiveLimits, after.effectiveLimits)
            XCTAssertEqual(after.effectiveLimits[node.id]?.amount, 70)
            XCTAssertEqual(before.carryIn, after.carryIn)
        }
    }

    func testTimeZoneChangeRejectsCrossMonthOrMalformedHistoryWithoutGuessing() throws {
        let sgd = try CurrencyCode("SGD")
        let node = BudgetNode(name: "Category", limit: try Money(100, currency: sgd))
        let month = try date(9)
        let timeline = try BudgetConfigurationTimeline(currency: sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: month, nodes: [node])
        ])
        XCTAssertThrowsError(try BudgetReportingTimeZoneChange(nodes: [node], timeline: timeline,
            baseCurrency: sgd, asOf: month.addingTimeInterval(1_800),
            oldCalendar: calendar("Asia/Singapore"), newCalendar: calendar("GMT"))) {
            XCTAssertEqual($0 as? BudgetReportingConfigurationError, .currentMonthWouldChange)
        }
        let malformed = try BudgetConfigurationTimeline(currency: sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: month.addingTimeInterval(3_600), nodes: [node])
        ])
        XCTAssertThrowsError(try BudgetReportingTimeZoneChange(nodes: [node], timeline: malformed,
            baseCurrency: sgd, asOf: date(9, day: 6),
            oldCalendar: calendar("Asia/Singapore"), newCalendar: calendar("GMT"))) {
            XCTAssertEqual($0 as? BudgetReportingConfigurationError, .invalidMonthBoundary)
        }
    }
}
