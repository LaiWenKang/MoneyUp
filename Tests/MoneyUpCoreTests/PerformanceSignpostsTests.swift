import XCTest
@testable import MoneyUpCore

final class PerformanceSignpostsTests: XCTestCase {
    func testOperationInventoryUsesStablePayloadFreeNames() {
        XCTAssertEqual(
            MoneyUpPerformanceOperation.allCases.map(\.rawValue),
            [
                "StoreOpen",
                "Unlock",
                "LedgerLoad",
                "Save",
                "HistoryPage",
                "HistoryQuery",
                "CSVExport",
                "XLSXExport",
                "ArchiveExport",
                "ArchiveRestore",
                "ReceiptProcessing",
                "Projection",
                "DeterministicIntelligence",
                "UnlockToFirstUsefulContent",
                "TransactionSaveToPublication",
                "HistoryQueryToContent",
                "HistoryPageToContent",
                "CalendarDateComputation"
            ]
        )
        XCTAssertEqual(
            Set(MoneyUpPerformanceOperation.allCases.map(\.rawValue)).count,
            MoneyUpPerformanceOperation.allCases.count
        )
        XCTAssertEqual(
            MoneyUpPerformanceOutcome.allCases,
            [.success, .failure, .cancelled]
        )
    }
}
