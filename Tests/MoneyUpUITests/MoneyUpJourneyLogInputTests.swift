import XCTest

/// Log, round 4: a dimmed Save says what is missing, in the real
/// accessibility tree, and an amount typed from its decimal separator saves.
extension MoneyUpJourneyTests {
    func testDimmedSaveSaysWhatIsMissingAndAFractionTypedFromItsSeparatorSaves() {
        let app = launch()
        let amount = openLog(app)
        app.buttons["Income"].tap()
        let save = app.buttons["log-save"]
        expectFalse(save.isEnabled)
        expectEqual(save.value as? String, "Enter or confirm the amount.", "A dimmed Save must say why")

        type(".5", into: amount)
        let fieldError = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Enter a valid amount.")).firstMatch
        expectFalse(fieldError.exists, "\".5\" is half of one, not an error")
        eventually("isEnabled == true", save, "An amount typed from its separator did not become savable")
        save.tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout), "0.50 did not save")

        // A new book has one financial account: the transfer names what it lacks.
        app.buttons["Transfer"].tap()
        type("40", into: app.textFields["quick-log-amount"])
        expectFalse(save.isEnabled)
        expectEqual(save.value as? String, "Choose the receiving account.")
        attachScreenshot(app, "journey-log-save-reason-transfer")
    }
}
