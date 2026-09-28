@testable import MoneyUp
import XCTest

/// A Focus may hide or show amounts while it is on; when it ends, the user's
/// own choice returns, unless they changed amounts by hand in the meantime.
final class FocusFilterTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "moneyup.focus-tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var hides: Bool { MoneyAmountPrivacy.hidesAmounts(in: defaults) }

    private func setUserChoice(hides: Bool) {
        defaults.set(hides, forKey: MoneyAmountPrivacy.storageKey)
    }

    func testAFocusHidesAmountsAndItsEndRestoresTheUsersChoice() {
        setUserChoice(hides: false)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: true, in: defaults)
        XCTAssertTrue(hides)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: nil, in: defaults)
        XCTAssertFalse(hides)
        XCTAssertNil(defaults.object(forKey: MoneyAmountPrivacy.focusRestoreKey))
        XCTAssertNil(defaults.object(forKey: MoneyAmountPrivacy.focusAppliedKey))
    }

    func testAChangeByHandDuringTheFocusIsKept() {
        setUserChoice(hides: true)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: false, in: defaults)
        XCTAssertFalse(hides)
        setUserChoice(hides: true)  // the eye button, mid-Focus
        setUserChoice(hides: false)
        setUserChoice(hides: true)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: nil, in: defaults)
        XCTAssertTrue(hides, "Hidden by hand, and hidden it stays")

        setUserChoice(hides: false)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: true, in: defaults)
        setUserChoice(hides: false)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: nil, in: defaults)
        XCTAssertFalse(hides)
    }

    func testMovingBetweenFocusesKeepsTheOriginalChoice() {
        setUserChoice(hides: false)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: true, in: defaults)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: true, in: defaults)
        XCTAssertTrue(hides)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: nil, in: defaults)
        XCTAssertFalse(hides)
    }

    func testEndingWithNoFocusChangesNothing() {
        setUserChoice(hides: true)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: nil, in: defaults)
        XCTAssertTrue(hides)
        // A fresh install, with no choice made, still starts private.
        defaults.removeObject(forKey: MoneyAmountPrivacy.storageKey)
        MoneyAmountPrivacy.applyFocus(hidesAmounts: nil, in: defaults)
        XCTAssertTrue(hides)
    }
}
