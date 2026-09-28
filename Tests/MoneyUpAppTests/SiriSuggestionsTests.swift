@testable import MoneyUp
import XCTest

/// After a save Siri learns which Log was used, and nothing else.
@MainActor
final class SiriSuggestionsTests: XCTestCase {
    func testADonationNamesOnlyTheLogThatWasUsed() {
        for kind in QuickLogKind.allCases {
            let action = QuickLogSiriSuggestions.action(for: kind)
            // The suggestion reopens the same Log, with no unlock of its own.
            XCTAssertEqual(QuickLogLaunchMode(action).kind, kind)
            XCTAssertFalse(action.requiresUnlock)
        }
        // One closed parameter; no amount, payee, note, or identifier.
        let intent = OpenQuickLogIntent(action: .refund)
        XCTAssertEqual(Mirror(reflecting: intent).children.compactMap(\.label), ["_action"])
        XCTAssertEqual(intent.action, .refund)
    }
}
