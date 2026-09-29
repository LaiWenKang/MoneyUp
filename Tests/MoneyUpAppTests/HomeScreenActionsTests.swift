@testable import MoneyUp
import XCTest

/// Long-pressing the app icon offers data-free ways into Log. Only MoneyUp's
/// own item types map to an action, and only to the offered ones.
final class HomeScreenActionsTests: XCTestCase {
    func testOfferedActionsAreTheCommonDataFreeLogModes() {
        XCTAssertEqual(MoneyUpHomeScreenActions.offered, [.expense, .income, .smartEntry, .scanReceipt])
    }

    func testItemTypesMapBackToExactlyTheirAction() {
        for action in MoneyUpHomeScreenActions.offered {
            XCTAssertEqual(
                MoneyUpHomeScreenActions.action(forType: MoneyUpHomeScreenActions.typePrefix + action.rawValue),
                action
            )
        }
        // Not offered, not ours, or malformed: nothing opens.
        XCTAssertNil(MoneyUpHomeScreenActions.action(forType: MoneyUpHomeScreenActions.typePrefix + "transfer"))
        XCTAssertNil(MoneyUpHomeScreenActions.action(forType: "com.example.quick-action.expense"))
        XCTAssertNil(MoneyUpHomeScreenActions.action(forType: MoneyUpHomeScreenActions.typePrefix))
        XCTAssertNil(MoneyUpHomeScreenActions.action(forType: MoneyUpHomeScreenActions.typePrefix + "expense.extra"))
    }

    @MainActor
    func testTitlesAreTheReviewedShortTitlesInBothLanguages() throws {
        let bundle = Bundle(for: AppModel.self)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
            let localized = try XCTUnwrap(Bundle(path: path))
            for action in MoneyUpHomeScreenActions.offered {
                let key = MoneyUpHomeScreenActions.titleKey(for: action)
                let title = localized.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(title, key, "\(language) is missing \(key)")
                XCTAssertFalse(title.isEmpty)
            }
        }
    }
}
