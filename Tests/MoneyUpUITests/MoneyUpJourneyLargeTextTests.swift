import XCTest

/// At the largest system text size, the Saved banner must still say what was
/// saved: the amount is the confirmation, so it may not be cut off.
extension MoneyUpJourneyTests {
    func testLargestTextSizeKeepsTheSavedAmountWhole() throws {
        let app = launch(extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let amount = openLog(app)
        // Shown amounts: a mask is five fixed characters and would hide the cut.
        let show = app.navigationBars.buttons["Show amounts"]
        if show.waitForExistence(timeout: timeout) { show.tap() }
        type("12345.67", into: amount)
        dismissKeyboard(app)
        eventually("isEnabled == true", app.buttons["log-save"], "The expense did not become savable")
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout), "The expense did not save")
        attachScreenshot(app, "journey-ax5-saved-banner")
        let issues = try auditIssues(app, [.textClipped], screen: "Log AX5 after saving")
        let attachment = XCTAttachment(string: issues.joined(separator: "\n"))
        attachment.name = "journey-ax5-saved-banner-clipped"
        attachment.lifetime = .keepAlways
        add(attachment)
        expectTrue(issues.isEmpty, "Clipped text after saving at AX5:\n" + issues.joined(separator: "\n"))
    }
}
