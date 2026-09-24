import XCTest

/// End-to-end journeys driven through the real UI. The debug-only harness
/// (`-MoneyUpUITest`) opens a seeded, fixed-key temporary book through the
/// normal startup path, so no step here bypasses production logic except the
/// Face ID/Keychain prompt a simulator cannot answer.
@MainActor
final class MoneyUpJourneyTests: XCTestCase {
    let timeout: TimeInterval = 15

    // Values are evaluated on the main actor before they reach XCTest, whose
    // autoclosures are nonisolated under Swift 6.
    func expectTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }

    func expectFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, message, file: file, line: line)
    }

    func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs, rhs, message, file: file, line: line)
    }

    func expectAtMost(_ lhs: Int, _ rhs: Int, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(lhs, rhs, message, file: file, line: line)
    }

    @discardableResult
    func launch(
        favourites: Bool = false, locked: Bool = false, reset: Bool = true,
        language: String = "en", extra: [String] = []
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MoneyUpUITest", "-AppleLanguages", "(\(language))", "-AppleLocale", "en_SG"] + extra
            + (reset ? ["-MoneyUpUITestReset"] : [])
            + (favourites ? ["-MoneyUpUITestFavourites"] : [])
            + (locked ? ["-MoneyUpUITestStartLocked"] : [])
        app.launch()
        if locked {
            // Widget taps arrive after the phone is locked, never mid-startup.
            expectTrue(app.staticTexts["MoneyUp is locked"].waitForExistence(timeout: timeout)
                          || app.buttons["Unlock with passcode"].waitForExistence(timeout: timeout)
                          || language != "en", "App did not reach the locked state")
        } else {
            expectTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout), "Book did not open")
        }
        return app
    }

    func openLog(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons.element(boundBy: 2).tap()
        let amount = app.textFields["quick-log-amount"]
        expectTrue(amount.waitForExistence(timeout: timeout))
        return amount
    }

    /// Types like a person: a field hidden under the keypad is revealed
    /// first, and the text is confirmed to have landed in that field.
    func type(_ text: String, into field: XCUIElement,
              file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        expectTrue(field.waitForExistence(timeout: timeout), "Missing field", file: file, line: line)
        if !field.isHittable || (app.keyboards.count > 0 && !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false)) {
            dismissKeyboard(app)
            var attempts = 0
            while !field.isHittable && attempts < 4 { app.swipeUp(); attempts += 1 }
        }
        // A tap during a scroll or keyboard animation can land before the
        // field can take focus, or on the Save bar riding the keypad. Hide
        // the keypad, bring the field into view, and tap again.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for attempt in 0..<3 {
            if attempt > 0 {
                dismissKeyboard(app)
                if !field.isHittable { app.swipeUp() }
            }
            field.tap()
            let wait = XCTNSPredicateExpectation(predicate: focused, object: field)
            if XCTWaiter().wait(for: [wait], timeout: 3) == .completed { break }
        }
        field.typeText(text)
        let value = field.value as? String ?? ""
        expectTrue(value.contains(text) || value.contains("•"),
                      "Typed \(text.debugDescription) but the field shows \(value.debugDescription)",
                      file: file, line: line)
    }

    func dismissKeyboard(_ app: XCUIApplication) {
        let dismiss = app.buttons["log-dismiss-keyboard"]
        if dismiss.exists { dismiss.tap() }
    }

    func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        dismissKeyboard(app)
        let settings = app.navigationBars.buttons["Settings"]
        // Just after launch the tab bar can exist before it takes taps.
        for _ in 0..<3 where !settings.exists {
            app.tabBars.buttons.element(boundBy: 0).tap()
            if settings.waitForExistence(timeout: 5) { break }
        }
        expectTrue(settings.waitForExistence(timeout: timeout), "Settings is unreachable", file: file, line: line)
        settings.tap()
    }

    /// Waits for a state the app reaches asynchronously, such as Save
    /// becoming enabled once a fill has been applied.
    func eventually(_ format: String, _ element: XCUIElement, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        expectEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message,
                    file: file, line: line)
    }

    /// Delivers a widget/control deep link the way the system does, to the
    /// already-running app, and accepts the system's "Open in" prompt if shown.
    func openWidgetLink(_ path: String, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCUIDevice.shared.system.open(URL(string: "moneyup://quick-log/\(path)")!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
        expectTrue(app.wait(for: .runningForeground, timeout: timeout), file: file, line: line)
    }

    /// Lazy lists only materialise rows near the viewport.
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        var swipes = 0
        while !element.exists && swipes < maxSwipes { app.swipeUp(); swipes += 1 }
    }

    func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Positive paths

    /// The 1064.1 Log-tab crash reproduced only on a physical iPhone. This is
    /// the cheapest check that would have caught it; the device lane runs it.
    func testEveryTabOpensWithoutCrashing() {
        let app = launch(favourites: true)
        for tab in ["Today", "History", "Log", "Plan", "Assets", "Log", "Today"] {
            // Log focuses the amount field; its keypad covers the tab bar.
            let dismiss = app.buttons["log-dismiss-keyboard"]
            if dismiss.exists { dismiss.tap() }
            let button = app.tabBars.buttons[tab]
            expectTrue(button.waitForExistence(timeout: timeout), "Missing tab \(tab)")
            button.tap()
            expectEqual(app.state, .runningForeground, "App left the foreground on \(tab)")
            expectTrue(button.isSelected, "\(tab) did not open")
        }
        attachScreenshot(app, "journey-every-tab")
    }

    func testLogAnExpenseThenUndo() {
        let app = launch()
        type("12.5", into: openLog(app))
        app.buttons["log-save"].tap()
        let undo = app.buttons["log-undo"]
        expectTrue(undo.waitForExistence(timeout: timeout), "Saved confirmation did not appear")
        attachScreenshot(app, "journey-saved")
        undo.tap()
        expectTrue(undo.waitForNonExistence(timeout: timeout), "Undo did not remove the entry")
    }

    func testFavouriteFillsTheFormAndSavesOnlyOnSave() {
        let app = launch(favourites: true)
        let amount = openLog(app)
        let lunch = app.buttons["quick-log-favourite-Lunch"]
        expectTrue(lunch.waitForExistence(timeout: timeout))
        lunch.tap()
        expectFalse(app.buttons["log-undo"].exists, "A favourite must never save by itself")
        amount.typeText("8")
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout))
    }

    func testSaveAsFavouriteFromTheSavedBanner() {
        let app = launch()
        type("4.5", into: openLog(app))
        type("Kopi", into: app.textFields["quick-log-payee"])
        app.buttons["log-save"].tap()
        let star = app.buttons["log-save-as-favourite"]
        expectTrue(star.waitForExistence(timeout: timeout))
        star.tap()
        let save = app.navigationBars.buttons["Save"]
        expectTrue(save.waitForExistence(timeout: timeout))
        attachScreenshot(app, "journey-favourite-editor")
        eventually("isEnabled == true", save, "The editor prefilled from Kopi must be savable")
        save.tap()
        attachScreenshot(app, "journey-after-favourite-save")
        // The favourites row is the first row of the form; scroll back to it.
        let chip = app.buttons["quick-log-favourite-Kopi"]
        var swipes = 0
        while !chip.exists && swipes < 6 { app.swipeDown(); swipes += 1 }
        expectTrue(chip.waitForExistence(timeout: timeout))
    }

    // MARK: Locked capture, widget route, and unlock

    func testWidgetRouteWhileLockedCapturesPrivatelyWithAFavourite() {
        let app = launch(favourites: true, locked: true)
        openWidgetLink("expense", in: app)
        let amount = app.textFields["locked-capture-amount"]
        expectTrue(amount.waitForExistence(timeout: timeout), "Locked capture did not open")
        let lunch = app.buttons["locked-favourite-Lunch"]
        expectTrue(lunch.waitForExistence(timeout: timeout), "Opted-in favourites are missing")
        lunch.tap()
        amount.tap()
        amount.typeText("8")
        let save = app.buttons["locked-capture-save"]
        expectTrue(save.isHittable, "Save must stay above the keyboard")
        save.tap()
        expectTrue(app.buttons["locked-capture-done"].waitForExistence(timeout: timeout))
        attachScreenshot(app, "journey-locked-captured")
        app.buttons["locked-capture-done"].tap()
    }

    func testLockedCaptureArrivesInLogWithItsFavouriteAfterUnlock() {
        let app = launch(favourites: true, locked: true)
        openWidgetLink("expense", in: app)
        let amount = app.textFields["locked-capture-amount"]
        expectTrue(amount.waitForExistence(timeout: timeout))
        app.buttons["locked-favourite-Lunch"].tap()
        amount.tap()
        amount.typeText("9")
        app.buttons["locked-capture-unlock"].tap()
        let payee = app.textFields["quick-log-payee"]
        expectTrue(payee.waitForExistence(timeout: timeout), "Unlock did not open Log")
        expectEqual(payee.value as? String, "Lunch", "The capture did not arrive in Log")
    }

    func testUnlockFromLockedCaptureShowsFavourites() {
        let app = launch(favourites: true, locked: true)
        openWidgetLink("expense", in: app)
        let unlock = app.buttons["locked-capture-unlock"]
        expectTrue(unlock.waitForExistence(timeout: timeout))
        unlock.tap()
        expectTrue(app.buttons["quick-log-favourite-Lunch"].waitForExistence(timeout: timeout))
    }

    // MARK: Negative paths and conflicts

    func testSaveIsUnavailableWithoutAnAmount() {
        let app = launch()
        _ = openLog(app)
        expectFalse(app.buttons["log-save"].isEnabled)
        type("abc", into: app.textFields["quick-log-amount"])
        expectFalse(app.buttons["log-save"].isEnabled, "Non-numeric input must not be savable")
    }

    func testWidgetRequestDuringAnUnfinishedEntryAsksFirst() {
        let app = launch()
        _ = openLog(app)
        type("Taxi", into: app.textFields["quick-log-payee"])
        openWidgetLink("income", in: app)
        let resume = app.buttons["Resume unfinished entry"]
        expectTrue(resume.waitForExistence(timeout: timeout), "Conflict prompt did not appear")
        resume.tap()
        expectEqual(app.textFields["quick-log-payee"].value as? String, "Taxi")
    }

    // MARK: Interruptions and relaunch

    func testUnfinishedEntrySurvivesBackgroundingAndRelaunch() {
        var app = launch()
        _ = openLog(app)
        type("Groceries", into: app.textFields["quick-log-payee"])
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()
        app = launch(reset: false)
        _ = openLog(app)
        expectEqual(app.textFields["quick-log-payee"].value as? String, "Groceries")
    }

    func testRepeatedWidgetTapsOpenOneLogWithoutDuplicates() {
        let app = launch()
        for _ in 0..<5 { openWidgetLink("expense", in: app) }
        let amount = app.textFields["quick-log-amount"]
        expectTrue(amount.waitForExistence(timeout: timeout))
        expectFalse(app.buttons["log-undo"].exists, "Routing must never save")
        expectEqual(app.textFields.matching(identifier: "quick-log-amount").count, 1)
    }

    // MARK: Accessibility audits

    func testAccessibilityAuditOfLogAndLockedCapture() throws {
        let app = launch(favourites: true)
        _ = openLog(app)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .trait])
        app.terminate()
        let locked = launch(favourites: true, locked: true)
        openWidgetLink("expense", in: locked)
        expectTrue(locked.textFields["locked-capture-amount"].waitForExistence(timeout: timeout))
        try locked.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .trait])
    }
}
