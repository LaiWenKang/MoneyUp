import Foundation
import MoneyUpCore
import XCTest

final class BudgetPeriodRecoveryTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: zone)
    }

    private func date(_ month: Int, day: Int = 1, hour: Int = 0, zone: String) throws -> Date {
        try XCTUnwrap(calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
    }

    func testLegacyZoneMismatchRecoversExactMonthsMoneyCarryMappingsAndIDs() throws {
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        for (oldZone, newZone) in [
            ("Asia/Singapore", "GMT"), ("GMT", "Asia/Singapore"),
            ("America/New_York", "Europe/London"), ("Pacific/Kiritimati", "America/Los_Angeles"),
            ("Asia/Kathmandu", "Australia/Adelaide")
        ] {
            let now = try date(9, day: 6, hour: 12, zone: oldZone)
            let node = BudgetNode(name: "Category", limit: try Money(100, currency: sgd),
                rolloverRule: .fullBalance, rolloverStartedAt: try date(1, zone: oldZone),
                monthlyAllocations: [try MonthlyBudgetAllocation(month: BudgetMonth(year: 2026, month: 9),
                    currency: usd, limit: Money(30, currency: usd))])
            let sourceID = UUID()
            let original = try BudgetConfigurationTimeline(currency: sgd, revisions: [
                BudgetConfigurationRevision(effectiveMonth: date(1, zone: oldZone), nodes: [node]),
                BudgetConfigurationRevision(effectiveMonth: date(9, zone: oldZone), nodes: [node],
                    carryMappings: [BudgetCarryMapping(sourceID: sourceID, targetID: node.id)],
                    openingCarry: [sourceID: Money(-30, currency: sgd)])
            ])
            XCTAssertThrowsError(try original.validateCurrentConfiguration(nodes: [node], baseCurrency: sgd,
                asOf: now, calendar: calendar(newZone))) {
                XCTAssertEqual($0 as? BudgetReportingConfigurationError, .invalidMonthBoundary)
            }
            let repair = try BudgetPeriodRecovery(nodes: [node], timeline: original, baseCurrency: sgd,
                asOf: now, calendar: calendar(newZone))
            try repair.timeline.validateCurrentConfiguration(nodes: repair.nodes, baseCurrency: sgd,
                asOf: now, calendar: calendar(newZone))
            XCTAssertEqual(repair.nodes[0].monthlyAllocations, node.monthlyAllocations)
            XCTAssertEqual(repair.nodes[0].limit, node.limit)
            XCTAssertEqual(repair.nodes[0].rolloverStartedAt, try date(1, zone: newZone))
            for (before, after) in zip(original.revisions, repair.timeline.revisions) {
                XCTAssertEqual(before.id, after.id)
                XCTAssertEqual(before.openingCarry, after.openingCarry)
                XCTAssertEqual(before.carryMappings, after.carryMappings)
                XCTAssertEqual(try BudgetMonth(containing: before.effectiveMonth, calendar: calendar(oldZone)),
                    try BudgetMonth(containing: after.effectiveMonth, calendar: calendar(newZone)))
            }
            let before = try BudgetRolloverEngine.snapshot(timeline: original, monthlySpending: [], asOf: now,
                calendar: calendar(oldZone))
            let after = try BudgetRolloverEngine.snapshot(timeline: repair.timeline, monthlySpending: [], asOf: now,
                calendar: calendar(newZone))
            XCTAssertEqual(before.effectiveLimits, after.effectiveLimits)
            XCTAssertEqual(after.effectiveLimits[node.id]?.amount, 70)
            XCTAssertEqual(before.carryIn, after.carryIn)
        }
    }

    func testRejectsArbitraryDatesAndMixedZoneRevisionsInsteadOfDroppingHistory() throws {
        let sgd = try CurrencyCode("SGD")
        let node = BudgetNode(name: "Category", limit: try Money(100, currency: sgd))
        for dates in [
            [try date(9, day: 15, zone: "GMT")],
            [try date(9, zone: "GMT"), try date(9, zone: "Asia/Singapore")]
        ] {
            let original = try BudgetConfigurationTimeline(currency: sgd, revisions: dates.map {
                BudgetConfigurationRevision(effectiveMonth: $0, nodes: [node])
            })
            XCTAssertThrowsError(try BudgetPeriodRecovery(nodes: [node], timeline: original, baseCurrency: sgd,
                asOf: date(9, day: 6, zone: "GMT"), calendar: calendar("Europe/London"))) {
                XCTAssertEqual($0 as? BudgetReportingConfigurationError, .invalidMonthBoundary)
            }
            XCTAssertEqual(original.revisions.count, dates.count)
        }
    }

    func testRejectsAmbiguousRolloverActivationAcrossCompatibleDSTZones() throws {
        let sgd = try CurrencyCode("SGD")
        // September midnight at UTC-4 fits New York and fixed UTC-4 regions.
        // This January instant is December in New York, January in UTC-4.
        let node = BudgetNode(name: "Category", limit: try Money(100, currency: sgd),
            rolloverRule: .fullBalance, rolloverStartedAt: try date(1, hour: 4, zone: "GMT"))
        let original = try BudgetConfigurationTimeline(currency: sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(9, zone: "America/New_York"), nodes: [node])
        ])
        XCTAssertThrowsError(try BudgetPeriodRecovery(nodes: [node], timeline: original, baseCurrency: sgd,
            asOf: date(9, day: 6, zone: "GMT"), calendar: calendar("GMT"))) {
            XCTAssertEqual($0 as? BudgetReportingConfigurationError, .invalidMonthBoundary)
        }
    }

    func testRejectsFinancialMismatchAndCrossMonthRecovery() throws {
        let sgd = try CurrencyCode("SGD")
        let node = BudgetNode(name: "Category", limit: try Money(100, currency: sgd))
        let original = try BudgetConfigurationTimeline(currency: sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(9, zone: "Asia/Singapore"), nodes: [node])
        ])
        var changed = node; changed.limit = try Money(101, currency: sgd)
        XCTAssertThrowsError(try BudgetPeriodRecovery(nodes: [changed], timeline: original, baseCurrency: sgd,
            asOf: date(9, day: 6, zone: "GMT"), calendar: calendar("GMT"))) {
            XCTAssertEqual($0 as? BudgetReportingConfigurationError, .currentConfigurationMismatch)
        }
        XCTAssertThrowsError(try BudgetPeriodRecovery(nodes: [node], timeline: original, baseCurrency: sgd,
            asOf: date(9, zone: "Asia/Singapore").addingTimeInterval(1_800), calendar: calendar("GMT"))) {
            XCTAssertEqual($0 as? BudgetReportingConfigurationError, .currentMonthWouldChange)
        }
        XCTAssertThrowsError(try BudgetPeriodRecovery(nodes: [node], timeline: original, baseCurrency: CurrencyCode("USD"),
            asOf: date(9, day: 6, zone: "GMT"), calendar: calendar("GMT"))) {
            XCTAssertEqual($0 as? BudgetReportingConfigurationError, .currencyMismatch)
        }
    }

    func testOriginalEvidenceRoundTripsWithoutChangingAnyField() throws {
        let sgd = try CurrencyCode("SGD")
        let node = BudgetNode(name: "Original category", limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly, rolloverStartedAt: try date(8, zone: "Asia/Singapore"))
        let timeline = try BudgetConfigurationTimeline(currency: sgd, revisions: [
            BudgetConfigurationRevision(effectiveMonth: date(9, zone: "Asia/Singapore"), nodes: [node])
        ])
        let original = BudgetPeriodRecoveryOriginal(nodes: [node], timeline: timeline, reportingTimeZoneIdentifier: "GMT")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BudgetPeriodRecoveryOriginal.self, from: data)
        try decoded.validate()
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(try JSONDecoder().decode(BudgetConfigurationTimeline.self, from: data), timeline)
    }
}
