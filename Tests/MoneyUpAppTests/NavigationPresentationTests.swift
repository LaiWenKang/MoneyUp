@testable import MoneyUp
import Foundation
import SwiftUI
import XCTest

final class NavigationPresentationTests: XCTestCase {
    func testPlanSelectorKeepsAllPeerSectionsVisibleAndUnambiguous() {
        XCTAssertEqual(PlanSection.ordered, PlanSection.allCases)
        XCTAssertEqual(Set(PlanSection.ordered.map(\.systemImage)).count, 4)
        XCTAssertEqual(Set(PlanSection.ordered.map(\.titleKeyString)).count, 4)

        for selection in PlanSection.ordered {
            let expanded = PlanSection.ordered.filter {
                PlanSectionSelectorPolicy.showsTitle(
                    for: $0,
                    selection: selection
                )
            }
            XCTAssertEqual(expanded, PlanSection.ordered)
        }
    }

    func testPlanSelectorFallsBackToMenuForAccessibilityTextSizes() {
        XCTAssertFalse(PlanSectionSelectorPolicy.usesMenu(at: .large))
        XCTAssertFalse(PlanSectionSelectorPolicy.usesMenu(at: .xxxLarge))
        XCTAssertTrue(PlanSectionSelectorPolicy.usesMenu(at: .accessibility1))
        XCTAssertTrue(PlanSectionSelectorPolicy.usesMenu(at: .accessibility5))
    }

    func testHistoryScopeSelectorExpandsOnlyTheCurrentScope() {
        XCTAssertEqual(
            Set(HistoryQuickRange.allCases.map(\.systemImage)).count,
            HistoryQuickRange.allCases.count
        )
        XCTAssertEqual(HistoryScopeSelectorPolicy.minimumTapDimension, 44)

        for selection in HistoryQuickRange.allCases {
            let expanded = HistoryQuickRange.allCases.filter {
                HistoryScopeSelectorPolicy.showsTitle(
                    for: $0,
                    selection: selection
                )
            }
            XCTAssertEqual(expanded, PlanSection.ordered)
        }
    }

    func testHistoryScopeSelectorUsesReadableMenuAtAccessibilitySizes() {
        XCTAssertFalse(
            HistoryScopeSelectorPolicy.usesMenu(
                at: .xxxLarge,
                selection: .today
            )
        )
        XCTAssertTrue(
            HistoryScopeSelectorPolicy.usesMenu(
                at: .accessibility1,
                selection: .today
            )
        )
        XCTAssertTrue(
            HistoryScopeSelectorPolicy.usesMenu(
                at: .accessibility5,
                selection: .month
            )
        )
        XCTAssertTrue(
            HistoryScopeSelectorPolicy.usesMenu(
                at: .large,
                selection: nil
            ),
            "A custom range must keep a visible text label"
        )
    }

    func testHistoryScopeLabelsAreBilingual() {
        XCTAssertEqual(
            HistoryQuickRange.allCases.map {
                AppLocalization.string(
                    $0.titleKeyString,
                    language: .english
                )
            },
            ["Today", "7 days", "Month", "All"]
        )
        XCTAssertEqual(
            HistoryQuickRange.allCases.map {
                AppLocalization.string(
                    $0.titleKeyString,
                    language: .simplifiedChinese
                )
            },
            ["今天", "7 天", "本月", "全部"]
        )
        XCTAssertEqual(
            AppLocalization.string(
                "history.scope.custom",
                language: .english
            ),
            "Custom range"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "history.scope.custom",
                language: .simplifiedChinese
            ),
            "自定义范围"
        )
    }

    func testRollingHistoryRangeRebasesAcrossDSTMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let firstDay = try date("2026-03-08T12:00:00Z")
        let nextDay = try date("2026-03-09T07:01:00Z")
        let accountID = UUID()
        let categoryID = UUID()
        var draft = HistoryFilterDraft(now: firstDay, calendar: calendar)
        draft.kind = .expense
        draft.accountID = accountID
        draft.categoryIDs = [categoryID]
        draft.minimumAmountText = "12.34"

        draft.applyQuickRange(.today, asOf: firstDay, calendar: calendar)
        let firstQuery = draft.query(searchText: "coffee", calendar: calendar)
        XCTAssertEqual(firstQuery.startDate, try date("2026-03-08T08:00:00Z"))
        XCTAssertEqual(
            firstQuery.endDateExclusive,
            try date("2026-03-09T07:00:00Z")
        )
        XCTAssertEqual(
            try XCTUnwrap(firstQuery.endDateExclusive).timeIntervalSince(
                try XCTUnwrap(firstQuery.startDate)
            ),
            23 * 60 * 60
        )

        let firstSnapshot = AppReportingSnapshot(
            instant: firstDay,
            calendar: calendar
        )
        let nextSnapshot = AppReportingSnapshot(
            instant: nextDay,
            calendar: calendar
        )
        XCTAssertTrue(
            HistoryRollingRangeRefreshPolicy.shouldReapply(
                range: .today,
                lastAppliedDay: firstSnapshot.reportingDayIdentity,
                currentDay: nextSnapshot.reportingDayIdentity
            )
        )

        draft.applyQuickRange(.today, asOf: nextDay, calendar: calendar)
        let nextQuery = draft.query(searchText: "coffee", calendar: calendar)
        XCTAssertEqual(nextQuery.startDate, try date("2026-03-09T07:00:00Z"))
        XCTAssertEqual(
            nextQuery.endDateExclusive,
            try date("2026-03-10T07:00:00Z")
        )
        XCTAssertEqual(nextQuery.kind, .expense)
        XCTAssertEqual(nextQuery.accountID, accountID)
        XCTAssertEqual(nextQuery.categoryIDs, Set([categoryID]))
        XCTAssertEqual(nextQuery.minimumAmount, Decimal(string: "12.34"))
    }

    func testEveryQuickRangeKeepsPreservedAdvancedFiltersVisible() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try date("2026-09-05T12:00:00Z")
        let accountID = UUID()
        var baseline = HistoryFilterDraft(now: now, calendar: calendar)
        baseline.kind = .expense
        baseline.accountID = accountID
        baseline.minimumAmountText = "12.34"
        baseline.maximumAmountText = "56.78"

        for range in HistoryQuickRange.allCases {
            var draft = baseline
            draft.applyQuickRange(range, asOf: now, calendar: calendar)

            XCTAssertEqual(draft.kind, .expense)
            XCTAssertEqual(draft.accountID, accountID)
            XCTAssertEqual(draft.minimumAmountText, "12.34")
            XCTAssertEqual(draft.maximumAmountText, "56.78")
            XCTAssertTrue(draft.hasNonDateAdvancedFilters)
            XCTAssertTrue(
                draft.showsAdvancedFilterIndicator(quickRange: range),
                "\(range) must not hide preserved non-date predicates"
            )
        }

        var dateOnly = HistoryFilterDraft(now: now, calendar: calendar)
        dateOnly.applyQuickRange(.today, asOf: now, calendar: calendar)
        XCTAssertFalse(
            dateOnly.showsAdvancedFilterIndicator(quickRange: .today),
            "The visible date shortcut is not itself a hidden advanced filter"
        )

        dateOnly.categoryIDs = [UUID()]
        XCTAssertTrue(
            dateOnly.showsAdvancedFilterIndicator(quickRange: .today),
            "Category keeps its explicit active-filter treatment"
        )
    }

    func testCustomAndAllHistoryRangesDoNotReapplyAtRollover() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let first = AppReportingSnapshot(
            instant: try date("2026-08-31T15:59:59Z"),
            calendar: calendar
        )
        let next = AppReportingSnapshot(
            instant: try date("2026-08-31T16:00:01Z"),
            calendar: calendar
        )

        let fixedRanges: [HistoryQuickRange?] = [nil, .all]
        for range in fixedRanges {
            XCTAssertFalse(
                HistoryRollingRangeRefreshPolicy.shouldReapply(
                    range: range,
                    lastAppliedDay: first.reportingDayIdentity,
                    currentDay: next.reportingDayIdentity
                )
            )
        }
    }

    func testReportingClockRearmsAfterBriefBackgroundAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let before = try date("2026-08-31T15:59:59Z")
        let after = try date("2026-08-31T16:00:01Z")
        var state = AppReportingClockState(
            snapshot: AppReportingSnapshot(
                instant: before,
                calendar: calendar
            )
        )
        let originalGeneration = state.generation
        XCTAssertGreaterThan(state.snapshot.monthElapsed, 0.999)

        state.cancelForInactivity()
        XCTAssertEqual(state.snapshot.instant, before)
        state.rearm(instant: after, calendar: calendar)

        XCTAssertEqual(state.generation, originalGeneration + 2)
        XCTAssertEqual(state.snapshot.instant, after)
        XCTAssertNotEqual(
            state.snapshot.reportingDayIdentity,
            AppReportingSnapshot(
                instant: before,
                calendar: calendar
            ).reportingDayIdentity
        )
        XCTAssertEqual(calendar.component(.month, from: state.snapshot.instant), 9)
        XCTAssertLessThan(state.snapshot.monthElapsed, 0.001)
    }

    func testHistoryCategoryFilterStatePreservesAllSelectionShapes() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(
            HistoryCategoryFilterState(categoryIDs: nil),
            .all
        )
        XCTAssertEqual(
            HistoryCategoryFilterState(categoryIDs: [first]),
            .category(first)
        )
        XCTAssertEqual(
            HistoryCategoryFilterState(categoryIDs: [first, second]),
            .group(2)
        )
        XCTAssertEqual(
            HistoryCategoryFilterState(categoryIDs: []),
            .group(0)
        )
    }

    func testHistoryCrossTabOriginIsConsumedExactlyOnce() {
        var state = HistoryCrossTabNavigationState()
        XCTAssertNil(state.origin)
        XCTAssertNil(state.consumeReturnDestination())

        state.record(origin: .log)
        XCTAssertEqual(state.origin, .log)
        XCTAssertEqual(state.consumeReturnDestination(), .log)
        XCTAssertNil(state.origin)
        XCTAssertNil(state.consumeReturnDestination())
    }

    func testDirectTabSelectionClearsAStaleHistoryOrigin() {
        var state = HistoryCrossTabNavigationState()
        state.record(origin: .today)

        state.clearForDirectTabSelection()

        XCTAssertNil(state.origin)
        XCTAssertNil(state.consumeReturnDestination())
    }

    func testNewestGenuineHistoryRouteReplacesAnUnconsumedOrigin() {
        var state = HistoryCrossTabNavigationState()
        state.record(origin: .today)
        state.record(origin: .plan)

        XCTAssertEqual(state.consumeReturnDestination(), .plan)
        XCTAssertNil(state.consumeReturnDestination())
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
