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

    /// Release QA in Simplified Chinese at a large text size, with amounts
    /// hidden as the journeys ship them: an expense is logged, appears in
    /// History without its amount, is found by search, and opens in the
    /// editor with every field below the amount clear of the keyboard.
    func testChineseCoreFlowAtALargeTextSizeKeepsAmountsHiddenAndFieldsClear() {
        let app = launch(language: "zh-Hans", extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ])
        logBookshopExpense(in: app)
        app.tabBars.buttons.element(boundBy: 1).tap()
        savedEntry(in: app, missing: "The saved entry is missing from History")
        let any = app.descendants(matching: .any)
        expectTrue(any.matching(NSPredicate(format: "label CONTAINS %@", "隐藏的金额")).count > 0,
                   "History does not say its amounts are hidden")
        expectEqual(any.matching(NSPredicate(format: "label CONTAINS %@", "18.00")).count, 0,
                    "History shows an amount while amounts are hidden")
        attachScreenshot(app, "release-qa-zh-ax3-history-hidden")
        let search = app.searchFields.firstMatch
        expectTrue(search.waitForExistence(timeout: timeout), "History has no search field")
        search.tap()
        // Return submits the search and leaves the list to the found entry.
        search.typeText("Book\n")
        savedEntry(in: app, missing: "Search did not find the entry by name").tap()
        let problems = editorFieldsCovered(in: app, labels: .chinese, variant: "zh-ax3")
        expectTrue(problems.isEmpty, "Covered while typing:\n" + problems.joined(separator: "\n"))
    }

    /// The editor's labels in each language the journeys check.
    private struct EditorLabels {
        let title, split, splitAmount, splitNote, payee, note: String

        static let english = EditorLabels(
            title: "Edit transaction", split: "Split across categories",
            splitAmount: "Split 2 amount", splitNote: "Split 2 note (optional)",
            payee: "Title or merchant (optional)", note: "Description or notes (optional)")
        static let chinese = EditorLabels(
            title: "编辑交易", split: "拆分至多个分类",
            splitAmount: "第 2 条拆分金额", splitNote: "第 2 条拆分备注（可选）",
            payee: "标题或商户（可选）", note: "描述或备注（可选）")
    }

    /// Logs an expense of 18 at Bookshop from Log.
    private func logBookshopExpense(in app: XCUIApplication) {
        type("18", into: openLog(app))
        // On a short screen at a large text size the payee row is below the
        // fold, and the form builds only the rows it shows: hide the keypad
        // and scroll to it, as a person would, before typing.
        let payee = app.textFields["quick-log-payee"]
        dismissKeyboard(app)
        reveal(payee, in: app)
        type("Bookshop", into: payee)
        dismissKeyboard(app)
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout), "The expense did not save")
        dismissKeyboard(app)
    }

    /// Logs one expense, opens it from History, splits it, and focuses each
    /// field below the amount: the last split line's amount and note, then
    /// payee and note.
    private func editorFieldsCoveredByTheKeyboard(textSize: String?, variant: String) -> [String] {
        let app = launch(extra: textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        logBookshopExpense(in: app)
        app.tabBars.buttons.element(boundBy: 1).tap()
        savedEntry(in: app, missing: "The saved entry is missing from History").tap()
        return editorFieldsCovered(in: app, labels: .english, variant: variant)
    }

    /// History's row for the Bookshop expense. History lists it below its
    /// search, range and summary; on a short screen at a large text size the
    /// row starts below the fold, and the list builds only rows it shows.
    @discardableResult
    private func savedEntry(in app: XCUIApplication, missing: String) -> XCUIElement {
        let row = app.staticTexts["Bookshop"].firstMatch
        if !row.waitForExistence(timeout: 5) { reveal(row, in: app) }
        expectTrue(row.waitForExistence(timeout: timeout), missing)
        return row
    }

    /// In the editor just opened: turns on the split, then checks the split
    /// line, payee and note top to bottom, as the form lays them out.
    private func editorFieldsCovered(in app: XCUIApplication, labels: EditorLabels, variant: String) -> [String] {
        let editor = app.navigationBars[labels.title]
        expectTrue(editor.waitForExistence(timeout: timeout), "The editor did not open")
        let split = app.switches[labels.split].firstMatch
        reveal(split, in: app)
        guard split.exists else { return ["\(variant): the split switch is missing"] }
        split.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        var problems: [String] = []
        for label in [labels.splitAmount, labels.splitNote, labels.payee, labels.note] {
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
        reveal(field, in: app)
        guard field.exists else {
            printScreen(app)
            return "\(name): the field is missing"
        }
        // A tap during a scroll or keyboard animation can land before the
        // field can take focus: hide the keyboard, reveal, and tap again.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        var hasFocus = false
        for attempt in 0..<3 where !hasFocus {
            if attempt > 0 {
                hideKeyboard(app)
                reveal(field, in: app)
            }
            field.tap()
            let wait = XCTNSPredicateExpectation(predicate: focused, object: field)
            hasFocus = XCTWaiter().wait(for: [wait], timeout: 3) == .completed
        }
        guard hasFocus else {
            printScreen(app)
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

    /// A lazy form only holds rows near the screen, and every field checked
    /// here lies further down than the last: drag the form up in short, slow
    /// steps until the field exists, then nudge it clear of the screen edges.
    private func reveal(_ field: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0..<12 where !field.exists {
            // Drag in the part of the screen a keyboard leaves free.
            let keyboard = app.keyboards.firstMatch
            let free = keyboard.exists && window.frame.height > 0
                ? keyboard.frame.minY / window.frame.height : 1
            let from = min(0.7, free - 0.05), to = max(0.15, from - 0.25)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from)).press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        if field.exists && !field.isHittable { bringIntoView(field, in: app) }
    }

    /// The editor's keyboard has a Done bar; Log has its own hide button.
    private func hideKeyboard(_ app: XCUIApplication) {
        let done = app.toolbars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        if done.exists { done.tap() } else { dismissKeyboard(app) }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }
}
