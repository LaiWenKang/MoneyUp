import XCTest

/// Words said to Siri arrive through the same intent a shortcut runs. They fill
/// Smart Entry in Log and are read there; only the person's tap on Save writes.
extension MoneyUpJourneyTests {
    /// Starts the app as a shortcut run would: the intent runs once the book is
    /// open (or closed or covered), before anything else is touched.
    private func launchWithWords(_ words: String, startingAs state: [String] = [],
                                 file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MoneyUpUITest", "-MoneyUpUITestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_SG",
                               "-moneyup.privacy.hide-amounts", "NO", "-MoneyUpUITestWords", words] + state
        app.launch()
        return app
    }

    private func smartEntryField(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["quick-log-smart-input"]
        return field.waitForExistence(timeout: timeout) ? field : app.textViews["quick-log-smart-input"]
    }

    func testWordsFromSiriFillSmartEntryAndNothingIsSavedUntilSaveIsTapped() {
        let app = launchWithWords("coffee 4.50")
        let smart = smartEntryField(in: app)
        expectTrue(smart.waitForExistence(timeout: timeout), "Log did not open at Smart Entry")
        eventually("value CONTAINS 'coffee 4.50'", smart, "The words were not filled in")
        let amount = app.textFields["quick-log-amount"]
        eventually("value == '4.5'", amount, "The words were not read into an amount")
        expectFalse(app.buttons["log-undo"].exists, "Words from Siri must never save by themselves")
        attachScreenshot(app, "journey-siri-words-prefilled")

        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout), "Save did not confirm")
    }

    /// While the auto-lock cover is up, every Log request opens Log alone with
    /// no Face ID, and the words are in it like any other request.
    func testWordsOpenAtOnceWhileTheBookIsCovered() {
        let app = launchWithWords("lunch 12.50", startingAs: ["-MoneyUpUITestStartCovered", "-MoneyUpUITestDenyScreenUnlock"])
        let smart = smartEntryField(in: app)
        expectTrue(smart.waitForExistence(timeout: timeout), "Smart Entry did not open over the cover")
        eventually("value CONTAINS 'lunch 12.50'", smart, "The words were not filled in over the cover")
        expectFalse(app.buttons["log-undo"].exists, "Words must never save by themselves")
    }

    /// A closed book opens through the normal unlock first; the words wait in
    /// memory for that and are in Smart Entry when Log appears.
    func testWordsSurviveTheUnlockOfAClosedBook() {
        let app = launchWithWords("lunch 12.50", startingAs: ["-MoneyUpUITestStartLocked"])
        let smart = smartEntryField(in: app)
        expectTrue(smart.waitForExistence(timeout: timeout), "Smart Entry did not open after the unlock")
        eventually("value CONTAINS 'lunch 12.50'", smart, "The words did not survive the unlock")
        expectFalse(app.buttons["log-undo"].exists, "Words must never save by themselves")
    }
}
