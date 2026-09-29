@testable import MoneyUp
import XCTest

/// History opens on Today, so a search used to look only at today. A search
/// now looks through every date and hands the range back when it clears.
final class HistorySearchScopeTests: XCTestCase {
    private typealias Policy = HistorySearchScopePolicy

    func testStartingASearchOnARollingRangeSearchesEveryDate() {
        for range in [HistoryQuickRange.today, .sevenDays, .month] {
            let state = Policy.applying(search: "kopi", after: "", to: .init(range: range))
            XCTAssertEqual(state, .init(range: .all, rangeBeforeSearch: range), "\(range)")
        }
    }

    func testClearingTheSearchBringsTheRangeBack() {
        let searching = Policy.applying(search: "kopi", after: "", to: .init(range: .today))
        let refined = Policy.applying(search: "kopi tiam", after: "kopi", to: searching)
        XCTAssertEqual(refined, searching, "Refining a search keeps it on every date")
        XCTAssertEqual(
            Policy.applying(search: "", after: "kopi tiam", to: refined),
            .init(range: .today, rangeBeforeSearch: nil)
        )
    }

    func testARangeChosenDuringTheSearchIsKept() {
        var state = Policy.applying(search: "kopi", after: "", to: .init(range: .today))
        state.range = .month
        XCTAssertEqual(
            Policy.applying(search: "", after: "kopi", to: state),
            .init(range: .month, rangeBeforeSearch: nil)
        )
    }

    func testAllDatesAndCustomRangesAreLeftAlone() {
        XCTAssertEqual(
            Policy.applying(search: "kopi", after: "", to: .init(range: .all)),
            .init(range: .all, rangeBeforeSearch: nil)
        )
        // A custom date range (no quick range) is the user's explicit choice.
        XCTAssertEqual(
            Policy.applying(search: "kopi", after: "", to: .init(range: nil)),
            .init(range: nil, rangeBeforeSearch: nil)
        )
    }

    func testWhitespaceIsNotASearch() {
        XCTAssertEqual(
            Policy.applying(search: "   ", after: "", to: .init(range: .today)),
            .init(range: .today, rangeBeforeSearch: nil)
        )
    }
}
