import Foundation
@testable import MoneyUp
import XCTest

/// Guards the one way a layout preference could stop being harmless.
///
/// Remembering which cards a person leaves open is safe only while the keys
/// describe screen furniture. A key built by interpolating a category, account,
/// or payee identifier would move book content into unencrypted defaults, so
/// the closed key set is asserted rather than assumed.
final class MoneyUpDisclosureTests: XCTestCase {
    private static let allowedKey = try? NSRegularExpression(
        pattern: "^moneyup\\.disclosure\\.[a-z][a-z0-9-]*$"
    )

    func testDisclosureKeysAreNamespacedAndCarryNoBookContent() throws {
        let pattern = try XCTUnwrap(Self.allowedKey)
        for section in MoneyUpDisclosureSection.allCases {
            let key = section.rawValue
            let range = NSRange(key.startIndex..., in: key)
            XCTAssertEqual(
                pattern.numberOfMatches(in: key, range: range),
                1,
                "\(key) is not a fixed, lowercase, namespaced layout key"
            )
            // A UUID reaching a preference key is the exact failure this
            // guards, and every UUID form contains one of these.
            XCTAssertFalse(key.contains(where: \.isUppercase), key)
            XCTAssertFalse(key.contains("_"), key)
        }
    }

    func testDisclosureKeysAreUniqueAndDoNotShadowOtherPreferences() {
        let keys = MoneyUpDisclosureSection.allCases.map(\.rawValue)

        XCTAssertEqual(Set(keys).count, keys.count, "duplicate layout key")
        XCTAssertFalse(keys.contains(AppLanguagePreference.storageKey))
        XCTAssertFalse(keys.contains(AppModel.lockedQuickCapturePreferenceKey))
    }

    func testEveryDisclosureSectionIsReachableFromItsRawValue() {
        for section in MoneyUpDisclosureSection.allCases {
            XCTAssertEqual(
                MoneyUpDisclosureSection(rawValue: section.rawValue),
                section
            )
        }
    }
}
