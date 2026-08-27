import Foundation
@testable import MoneyUpCore
import XCTest

final class BudgetRolloverTests: XCTestCase {
    private let calendar = FinancialPeriodBoundary.gregorianCalendar(
        timeZoneIdentifier: "Asia/Singapore"
    )

    func testLegacyNodeDefaultsToNoRolloverAndNoActivation() throws {
        let sgd = try CurrencyCode("SGD")
        let node = BudgetNode(
            name: "Food",
            limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: date(2026, 1, 1)
        )
        let encoded = try JSONEncoder().encode(node)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "rolloverRule")
        object.removeValue(forKey: "rolloverStartedAt")

        let decoded = try JSONDecoder().decode(
            BudgetNode.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.rolloverRule, .none)
        XCTAssertNil(decoded.rolloverStartedAt)
    }

    func testPositiveOnlyCarriesUnusedBalanceAcrossEmptyMonths() throws {
        let sgd = try CurrencyCode("SGD")
        let id = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [BudgetNode(
                id: id,
                name: "Travel",
                limit: try Money(100, currency: sgd),
                rolloverRule: .positiveOnly,
                rolloverStartedAt: date(2026, 1, 15)
            )]
        )

        let result = try BudgetRolloverEngine.snapshot(
            tree: tree,
            monthlySpending: [MonthlyBudgetSpending(
                monthStart: date(2026, 1, 20),
                directSpending: [id: try Money(40, currency: sgd)]
            )],
            asOf: date(2026, 3, 10),
            calendar: calendar
        )

        // January leaves 60. February opens at 160 and leaves all 160, so
        // March opens at 260. A missing month is zero spending, not zero budget.
        XCTAssertEqual(result.carryIn[id]?.amount, 160)
        XCTAssertEqual(result.effectiveLimits[id]?.amount, 260)
    }

    func testPositiveOnlyDoesNotPunishNextMonthForOverspending() throws {
        let sgd = try CurrencyCode("SGD")
        let id = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [BudgetNode(
                id: id,
                name: "Dining",
                limit: try Money(100, currency: sgd),
                rolloverRule: .positiveOnly,
                rolloverStartedAt: date(2026, 1, 1)
            )]
        )

        let result = try BudgetRolloverEngine.snapshot(
            tree: tree,
            monthlySpending: [MonthlyBudgetSpending(
                monthStart: date(2026, 1, 1),
                directSpending: [id: try Money(130, currency: sgd)]
            )],
            asOf: date(2026, 2, 1),
            calendar: calendar
        )

        XCTAssertNil(result.carryIn[id])
        XCTAssertEqual(result.effectiveLimits[id]?.amount, 100)
    }

    func testFullBalanceCarriesOverspendingAsSignedDecimal() throws {
        let sgd = try CurrencyCode("SGD")
        let id = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [BudgetNode(
                id: id,
                name: "Flexible",
                limit: try Money(100, currency: sgd),
                rolloverRule: .fullBalance,
                rolloverStartedAt: date(2026, 1, 1)
            )]
        )

        let result = try BudgetRolloverEngine.snapshot(
            tree: tree,
            monthlySpending: [MonthlyBudgetSpending(
                monthStart: date(2026, 1, 1),
                directSpending: [id: try Money(
                    Decimal(string: "130.25")!,
                    currency: sgd
                )]
            )],
            asOf: date(2026, 2, 1),
            calendar: calendar
        )

        XCTAssertEqual(result.carryIn[id]?.amount, Decimal(string: "-30.25"))
        XCTAssertEqual(result.effectiveLimits[id]?.amount, Decimal(string: "69.75"))
    }

    func testNestedSpendingRollsIntoParentBeforeCarryIsCalculated() throws {
        let sgd = try CurrencyCode("SGD")
        let parentID = UUID()
        let childID = UUID()
        let tree = try BudgetTree(
            currency: sgd,
            nodes: [
                BudgetNode(
                    id: parentID,
                    name: "Essentials",
                    limit: try Money(500, currency: sgd),
                    rolloverRule: .positiveOnly,
                    rolloverStartedAt: date(2026, 1, 1)
                ),
                BudgetNode(id: childID, parentID: parentID, name: "Food")
            ]
        )

        let result = try BudgetRolloverEngine.snapshot(
            tree: tree,
            monthlySpending: [MonthlyBudgetSpending(
                monthStart: date(2026, 1, 1),
                directSpending: [childID: try Money(125, currency: sgd)]
            )],
            asOf: date(2026, 2, 1),
            calendar: calendar
        )

        XCTAssertEqual(result.carryIn[parentID]?.amount, 375)
        XCTAssertEqual(result.effectiveLimits[parentID]?.amount, 875)
    }

    func testAugustLimitRevisionDoesNotRecomputeJanuaryThroughJuly() throws {
        let sgd = try CurrencyCode("SGD")
        let id = UUID()
        let januaryNode = BudgetNode(
            id: id,
            name: "Travel",
            limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: month(2026, 1)
        )
        var augustNode = januaryNode
        augustNode.limit = try Money(200, currency: sgd)
        let timeline = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 1),
                    nodes: [januaryNode]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 8),
                    nodes: [augustNode]
                )
            ]
        )
        let spending = try (1...7).map { value in
            MonthlyBudgetSpending(
                monthStart: month(2026, value),
                directSpending: [id: try Money(10, currency: sgd)]
            )
        }

        let result = try BudgetRolloverEngine.snapshot(
            timeline: timeline,
            monthlySpending: spending,
            asOf: date(2026, 8, 15),
            calendar: calendar
        )

        XCTAssertEqual(result.carryIn[id]?.amount, 630)
        XCTAssertEqual(result.effectiveLimits[id]?.amount, 830)
    }

    func testAugustRuleRevisionLeavesClosedMonthRuleHistoryImmutable() throws {
        let sgd = try CurrencyCode("SGD")
        let id = UUID()
        let januaryNode = BudgetNode(
            id: id,
            name: "Flexible",
            limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: month(2026, 1)
        )
        var augustNode = januaryNode
        augustNode.rolloverRule = .fullBalance
        let timeline = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 1),
                    nodes: [januaryNode]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 8),
                    nodes: [augustNode]
                )
            ]
        )

        let result = try BudgetRolloverEngine.snapshot(
            timeline: timeline,
            monthlySpending: [MonthlyBudgetSpending(
                monthStart: month(2026, 1),
                directSpending: [id: try Money(150, currency: sgd)]
            )],
            asOf: date(2026, 8, 15),
            calendar: calendar
        )

        XCTAssertEqual(result.carryIn[id]?.amount, 600)
        XCTAssertEqual(result.effectiveLimits[id]?.amount, 700)
    }

    func testAugustHierarchyRevisionDoesNotReparentHistoricalSpending() throws {
        let sgd = try CurrencyCode("SGD")
        let firstParentID = UUID()
        let secondParentID = UUID()
        let childID = UUID()
        let firstParent = BudgetNode(
            id: firstParentID,
            name: "Essentials",
            limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: month(2026, 1)
        )
        let secondParent = BudgetNode(id: secondParentID, name: "Other")
        let januaryChild = BudgetNode(
            id: childID,
            parentID: firstParentID,
            name: "Food"
        )
        let augustChild = BudgetNode(
            id: childID,
            parentID: secondParentID,
            name: "Food"
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 1),
                    nodes: [firstParent, secondParent, januaryChild]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 8),
                    nodes: [firstParent, secondParent, augustChild]
                )
            ]
        )
        let spending = try (1...7).map { value in
            MonthlyBudgetSpending(
                monthStart: month(2026, value),
                directSpending: [childID: try Money(10, currency: sgd)]
            )
        }

        let result = try BudgetRolloverEngine.snapshot(
            timeline: timeline,
            monthlySpending: spending,
            asOf: date(2026, 8, 15),
            calendar: calendar
        )

        XCTAssertEqual(result.carryIn[firstParentID]?.amount, 630)
        XCTAssertEqual(result.effectiveLimits[firstParentID]?.amount, 730)
    }

    func testMergeRevisionTransfersBothExactCarryBalancesToTarget() throws {
        let sgd = try CurrencyCode("SGD")
        let sourceID = UUID()
        let targetID = UUID()
        let source = BudgetNode(
            id: sourceID,
            name: "Source",
            limit: try Money(100, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: month(2026, 1)
        )
        let target = BudgetNode(
            id: targetID,
            name: "Target",
            limit: try Money(50, currency: sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: month(2026, 1)
        )
        var mergedTarget = target
        mergedTarget.limit = try Money(150, currency: sgd)
        let timeline = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 1),
                    nodes: [source, target]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: month(2026, 8),
                    nodes: [mergedTarget],
                    carryMappings: [BudgetCarryMapping(
                        sourceID: sourceID,
                        targetID: targetID
                    )]
                )
            ]
        )

        let result = try BudgetRolloverEngine.snapshot(
            timeline: timeline,
            monthlySpending: [],
            asOf: date(2026, 8, 15),
            calendar: calendar
        )

        XCTAssertEqual(result.carryIn[targetID]?.amount, 1_050)
        XCTAssertEqual(result.effectiveLimits[targetID]?.amount, 1_200)
        XCTAssertNil(result.carryIn[sourceID])
    }

    func testTimelineDecoderRejectsDuplicateEffectiveMonths() throws {
        let sgd = try CurrencyCode("SGD")
        let revision = BudgetConfigurationRevision(
            effectiveMonth: month(2026, 1),
            nodes: [BudgetNode(name: "Food")]
        )
        let valid = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [revision]
        )
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let revisions = try XCTUnwrap(object["revisions"] as? [[String: Any]])
        object["revisions"] = revisions + revisions
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BudgetConfigurationTimeline.self,
                from: corrupted
            )
        )
    }

    func testTimelineEncodingIsDeterministicAfterRevisionSorting() throws {
        let sgd = try CurrencyCode("SGD")
        let january = BudgetConfigurationRevision(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            effectiveMonth: month(2026, 1),
            nodes: [BudgetNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                name: "Food"
            )]
        )
        let august = BudgetConfigurationRevision(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            effectiveMonth: month(2026, 8),
            nodes: january.nodes
        )
        let first = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [august, january]
        )
        let second = try BudgetConfigurationTimeline(
            currency: sgd,
            revisions: [january, august]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
    }

    func testAttributionKeepsUTCPlus14CivilDayAfterReportingZoneTravel() throws {
        let sgd = try CurrencyCode("SGD")
        let utc = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 31,
            hour: 10,
            minute: 30
        )))
        let accountID = UUID()
        let categoryID = UUID()
        let entry = try TransactionFactory.expense(
            amount: try Money(10, currency: sgd),
            paidFrom: accountID,
            category: categoryID,
            occurredAt: instant
        )
        let attribution = try BudgetEntryAttribution(
            entry: entry,
            originTimeZoneIdentifier: "Pacific/Kiritimati"
        )
        let travelledCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Etc/GMT+12"
        )
        let attributed = try XCTUnwrap(
            attribution.attributedDate(in: travelledCalendar)
        )

        XCTAssertEqual(attribution.originDayKey, "2026-08-01")
        XCTAssertEqual(attribution.originUTCOffsetSeconds, 14 * 60 * 60)
        XCTAssertEqual(
            travelledCalendar.component(.month, from: attributed),
            8
        )
        XCTAssertEqual(travelledCalendar.component(.day, from: attributed), 1)
    }

    func testAttributionDecoderRejectsMismatchedDayAndInvalidZone() throws {
        let sgd = try CurrencyCode("SGD")
        let entry = try TransactionFactory.expense(
            amount: try Money(10, currency: sgd),
            paidFrom: UUID(),
            category: UUID(),
            occurredAt: date(2026, 8, 1)
        )
        let attribution = try BudgetEntryAttribution(
            entry: entry,
            originTimeZoneIdentifier: "Asia/Singapore"
        )
        let encoded = try JSONEncoder().encode(attribution)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["originDayKey"] = "2026-07-31"
        XCTAssertThrowsError(try JSONDecoder().decode(
            BudgetEntryAttribution.self,
            from: try JSONSerialization.data(withJSONObject: object)
        ))

        object["originDayKey"] = attribution.originDayKey
        object["originTimeZoneIdentifier"] = "Not/AZone"
        XCTAssertThrowsError(try JSONDecoder().decode(
            BudgetEntryAttribution.self,
            from: try JSONSerialization.data(withJSONObject: object)
        ))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
    }

    private func month(_ year: Int, _ month: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: 1,
            hour: 0
        ))!
    }
}
