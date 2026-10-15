import XCTest

/// Wherever a person types, the field stays in sight: above the keyboard and
/// whatever rides on it (the Done bar, Log's Save bar), and below the
/// navigation bar. Measured from frames once the screen's own scroll to the
/// focused field has settled, at the default and a large accessibility text
/// size, where rows are tallest. The field is first brought just into view
/// from below, as a person scrolling to it would leave it.
extension MoneyUpJourneyTests {
    func testEditingFromHistoryKeepsTheFieldAboveTheKeyboard() {
        let problems = editorFieldsCoveredByTheKeyboard(textSize: nil, variant: "default")
        expectTrue(problems.isEmpty, "Covered while typing:\n" + problems.joined(separator: "\n"))
    }

    func testEditingFromHistoryAtALargeTextSizeKeepsTheFieldAboveTheKeyboard() {
        let problems = editorFieldsCoveredByTheKeyboard(
            textSize: "UICTContentSizeCategoryAccessibilityXL", variant: "ax3")
        expectTrue(problems.isEmpty, "Covered while typing:\n" + problems.joined(separator: "\n"))
    }

    func testLogAtALargeTextSizeKeepsTheFieldAboveTheKeyboard() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        _ = openLog(app)
        let save = app.buttons["log-save"]
        var problems: [String] = []
        for (identifier, name) in [("quick-log-payee", "log-payee"), ("quick-log-note", "log-note")] {
            dismissKeyboard(app)
            let field = app.descendants(matching: .any)[identifier].firstMatch
            if let problem = coverage(of: field, named: "ax3-\(name)", in: app, below: nil, above: save) {
                problems.append(problem)
            }
        }
        expectTrue(problems.isEmpty, "Covered while typing:\n" + problems.joined(separator: "\n"))
    }

    /// Logs one expense, opens it from History and focuses each field below
    /// the amount, ending with the last split line's amount and note.
    private func editorFieldsCoveredByTheKeyboard(textSize: String?, variant: String) -> [String] {
        let app = launch(extra: textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        type("18", into: openLog(app))
        type("Bookshop", into: app.textFields["quick-log-payee"])
        dismissKeyboard(app)
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout), "The expense did not save")
        dismissKeyboard(app)
        app.tabBars.buttons.element(boundBy: 1).tap()
        let row = app.staticTexts["Bookshop"].firstMatch
        expectTrue(row.waitForExistence(timeout: timeout), "The saved entry is missing from History")
        row.tap()
        let editor = app.navigationBars["Edit transaction"]
        expectTrue(editor.waitForExistence(timeout: timeout), "The editor did not open")
        var problems: [String] = []
        for label in ["Title or merchant (optional)", "Description or notes (optional)"] {
            if let problem = coverage(of: textInput(label, in: app), named: "\(variant)-\(label)", in: app,
                                      below: editor, above: nil) {
                problems.append(problem)
            }
            hideKeyboard(app)
        }
        let split = app.switches["Split across categories"].firstMatch
        if !split.isHittable { bringIntoView(split, in: app) }
        guard split.exists else { return problems + ["\(variant): the split switch is missing"] }
        split.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        for label in ["Split 2 amount", "Split 2 note (optional)"] {
            if let problem = coverage(of: textInput(label, in: app), named: "\(variant)-\(label)", in: app,
                                      below: editor, above: nil) {
                problems.append(problem)
            }
            hideKeyboard(app)
        }
        return problems
    }

    /// A single-line or growing text input, found by its label or placeholder.
    private func textInput(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let types = [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue]
        return app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@ AND (label == %@ OR placeholderValue == %@)", types, label, label
        )).firstMatch
    }

    /// Focuses `field` and reports where it ended up if any part of it is
    /// under the navigation bar `below`, the keyboard, a bar riding the
    /// keyboard, or the control `above` (Log's Save bar); nil when it is clear.
    private func coverage(of field: XCUIElement, named name: String, in app: XCUIApplication,
                          below navigation: XCUIElement?, above pinned: XCUIElement?) -> String? {
        // A lazy form only holds rows near the screen: look for it, not wait.
        if !field.waitForExistence(timeout: 3) || !field.isHittable { bringIntoView(field, in: app) }
        guard field.exists else {
            printScreen(app)
            return "\(name): the field is missing"
        }
        field.tap()
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        guard XCTWaiter().wait(for: [focused], timeout: 5) == .completed else {
            return "\(name): the field did not take focus"
        }
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else { return "\(name): no keyboard appeared" }
        // The screen scrolls the focused row at once and again once the
        // keyboard has settled; judge after both.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 1.5)
        var top = keyboard.frame.minY
        for bar in app.toolbars.allElementsBoundByIndex where bar.frame.minY < top && bar.frame.maxY >= top - 2 {
            top = bar.frame.minY
        }
        if let pinned, pinned.exists {
            // The bar's padding above its button is part of the opaque bar.
            top = min(top, pinned.frame.minY - 8)
        }
        let ceiling = navigation.map { $0.frame.maxY } ?? 0
        let frame = field.frame
        attachScreenshot(app, "keyboard-\(name)")
        guard frame.maxY <= top + 1, frame.minY >= ceiling - 1 else {
            return "\(name): field y \(Int(frame.minY))–\(Int(frame.maxY)), clear area y \(Int(ceiling))–\(Int(top))"
        }
        return nil
    }

    /// The editor's keyboard has a Done bar; Log has its own hide button.
    private func hideKeyboard(_ app: XCUIApplication) {
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.exists { done.tap() } else { dismissKeyboard(app) }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }
}
