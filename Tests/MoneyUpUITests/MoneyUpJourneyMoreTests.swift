import XCTest

/// Broader journeys: every entry kind, Smart Entry, History, Settings,
/// favourites management, locking mid-entry, rapid taps, languages, large
/// text, and an accessibility audit of every tab.
extension MoneyUpJourneyTests {
    // MARK: Entry kinds and Smart Entry

    func testIncomeAndTransferEntriesSave() {
        let app = launch()
        let amount = openLog(app)
        app.buttons["Income"].tap()
        type("2500", into: amount)
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout), "Income did not save")
        app.buttons["Transfer"].tap()
        let transferAmount = app.textFields["quick-log-amount"]
        type("40", into: transferAmount)
        attachScreenshot(app, "journey-transfer-form")
        // A new book has one financial account, so a transfer must stay
        // unsavable rather than invent a destination.
        expectFalse(app.buttons["log-save"].isEnabled, "Transfer without a destination must not save")
    }

    func testSmartEntryFillsTheFormFromOnePhrase() {
        let app = launch()
        _ = openLog(app)
        let smart = app.textFields["quick-log-smart-input"].exists
            ? app.textFields["quick-log-smart-input"] : app.textViews["quick-log-smart-input"]
        expectTrue(smart.waitForExistence(timeout: timeout))
        type("lunch 12.50", into: smart)
        let fill = app.buttons["quick-log-smart-fill"]
        expectTrue(fill.waitForExistence(timeout: timeout))
        // A person must be able to reach Fill with the keypad up; the Save
        // bar rides the keypad and must never cover it.
        let keypad = app.keyboards.firstMatch
        attachScreenshot(app, "journey-smart-before-fill")
        expectTrue(fill.isHittable, "Fill is covered: fill \(fill.frame), save "
            + "\(app.buttons["log-save"].frame), keypad \(keypad.exists ? keypad.frame : .zero)")
        fill.tap()
        dismissKeyboard(app)
        expectTrue(app.buttons["log-save"].waitForExistence(timeout: timeout))
        eventually("isEnabled == true", app.buttons["log-save"], "Smart Entry did not produce a savable entry")
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout))
    }

    // MARK: History

    func testSavedEntryAppearsInHistoryAndSearchFindsIt() {
        let app = launch()
        type("18", into: openLog(app))
        type("Bookshop", into: app.textFields["quick-log-payee"])
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout))
        dismissKeyboard(app)
        app.tabBars.buttons.element(boundBy: 1).tap()
        expectTrue(app.staticTexts["Bookshop"].firstMatch.waitForExistence(timeout: timeout),
                      "The saved entry is missing from History")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("Book")
            expectTrue(app.staticTexts["Bookshop"].firstMatch.waitForExistence(timeout: timeout))
            search.typeText("zzz")
            expectTrue(app.staticTexts["Bookshop"].firstMatch.waitForNonExistence(timeout: timeout),
                          "Search must filter out non-matching entries")
        }
    }

    // MARK: Duplicate protection

    func testRapidSaveTapsRecordOneEntry() {
        let app = launch()
        type("7", into: openLog(app))
        let save = app.buttons["log-save"]
        eventually("isEnabled == true", save, "The entry never became savable")
        for _ in 0..<5 where save.isEnabled { save.tap() }
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout))
        dismissKeyboard(app)
        app.tabBars.buttons.element(boundBy: 1).tap()
        let rows = app.cells.matching(NSPredicate(format: "label CONTAINS[c] '7'"))
        expectAtMost(rows.count, 1, "Five rapid taps must not create duplicate entries")
    }

    // MARK: Settings and favourites management

    func testWidgetsAndQuickAccessManagesFavouritesAndPrivacy() {
        let app = launch()
        openSettings(app)
        let row = app.buttons["settings-widgets-quick-access"]
        scrollTo(row, in: app)
        expectTrue(row.waitForExistence(timeout: timeout))
        row.tap()
        let newFavourite = app.buttons["New favourite"]
        if !newFavourite.waitForExistence(timeout: 5) { app.swipeUp() }
        expectTrue(newFavourite.waitForExistence(timeout: timeout))
        newFavourite.tap()
        let name = app.textFields["Name"]
        expectTrue(name.waitForExistence(timeout: timeout))
        type("Taxi", into: name)
        app.navigationBars.buttons["Save"].tap()
        expectTrue(app.staticTexts["Taxi"].waitForExistence(timeout: timeout), "New favourite not listed")
        let optIn = app.switches["quick-access-favourites-while-locked"]
        scrollTo(optIn, in: app)
        expectEqual(optIn.value as? String, "0", "Showing favourites while locked must default off")
        // Tap the switch itself, not its two-line label, then allow the
        // encrypted profile write to publish the new value.
        optIn.switches.firstMatch.exists ? optIn.switches.firstMatch.tap()
            : optIn.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let turnedOn = NSPredicate(format: "value == '1'")
        expectEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: turnedOn, object: optIn)],
                                     timeout: timeout), .completed, "The opt-in did not turn on")
        attachScreenshot(app, "journey-quick-access")
    }

    // MARK: Interruptions

    func testLockingMidEntryKeepsTheDraftAfterUnlock() {
        let app = launch()
        _ = openLog(app)
        type("Parking", into: app.textFields["quick-log-payee"])
        openSettings(app)
        let lockNow = app.buttons["Lock now"]
        scrollTo(lockNow, in: app)
        lockNow.tap()
        let unlock = app.buttons["Unlock with passcode"]
        expectTrue(unlock.waitForExistence(timeout: timeout), "The app did not lock")
        unlock.tap()
        expectTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout), "Unlock failed")
        _ = openLog(app)
        expectEqual(app.textFields["quick-log-payee"].value as? String, "Parking",
                       "Locking must not discard an unfinished entry")
    }

    // MARK: Languages, text size, appearance

    func testSimplifiedChineseJourneyLogsAnExpense() {
        let app = launch(language: "zh-Hans")
        expectTrue(app.tabBars.buttons["记账"].waitForExistence(timeout: timeout))
        type("25", into: openLog(app))
        eventually("isEnabled == true", app.buttons["log-save"], "A Chinese-language entry must be savable")
        app.buttons["log-save"].tap()
        expectTrue(app.buttons["log-undo"].waitForExistence(timeout: timeout))
        attachScreenshot(app, "journey-zh-saved")
    }

    /// Runs an audit and returns every issue instead of stopping at the first,
    /// so one run lists everything to fix.
    func auditIssues(_ app: XCUIApplication, _ types: XCUIAccessibilityAuditType,
                     screen: String) throws -> [String] {
        var found: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            guard issue.element?.elementType != .key else { return true }
            let element = issue.element
            found.append("\(screen): \(issue.compactDescription) — \(element?.elementType.rawValue ?? 0) "
                + "'\(element?.label ?? "")' id '\(element?.identifier ?? "")' \(element?.frame ?? .zero)")
            return true
        }
        return found
    }

    func testLargestAccessibilityTextSizeKeepsLogUsable() throws {
        let app = launch(favourites: true, extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        type("9", into: openLog(app))
        expectTrue(app.buttons["log-save"].isHittable, "Save must stay reachable at AX5")
        dismissKeyboard(app)
        for _ in 0..<4 { app.swipeDown() }
        attachScreenshot(app, "journey-ax5-log")
        let issues = try auditIssues(app, [.textClipped], screen: "Log AX5")
        add(XCTAttachment(string: issues.joined(separator: "\n")))
        expectTrue(issues.isEmpty, "Clipped text at AX5:\n" + issues.joined(separator: "\n"))
    }

    func testAccessibilityAuditOfEveryTab() throws {
        let app = launch(favourites: true)
        var issues: [String] = []
        for index in 0..<5 {
            dismissKeyboard(app)
            let tab = app.tabBars.buttons.element(boundBy: index)
            let name = tab.label
            tab.tap()
            dismissKeyboard(app)
            issues += try auditIssues(app, [.sufficientElementDescription, .hitRegion, .trait], screen: name)
        }
        add(XCTAttachment(string: issues.joined(separator: "\n")))
        expectTrue(issues.isEmpty, "Accessibility issues:\n" + issues.joined(separator: "\n"))
    }

    func testAccessibilityAuditOfSettingsQuickAccessAndFavouriteEditor() throws {
        let app = launch(favourites: true)
        openSettings(app)
        var issues = try auditIssues(app, [.sufficientElementDescription, .hitRegion, .trait], screen: "Settings")
        let row = app.buttons["settings-widgets-quick-access"]
        scrollTo(row, in: app)
        row.tap()
        expectTrue(app.navigationBars["Widgets & Quick Access"].waitForExistence(timeout: timeout))
        issues += try auditIssues(app, [.sufficientElementDescription, .hitRegion, .trait], screen: "Quick Access")
        let newFavourite = app.buttons["New favourite"]
        scrollTo(newFavourite, in: app)
        newFavourite.tap()
        expectTrue(app.textFields["Name"].waitForExistence(timeout: timeout))
        issues += try auditIssues(app, [.sufficientElementDescription, .hitRegion, .trait], screen: "Favourite editor")
        add(XCTAttachment(string: issues.joined(separator: "\n")))
        expectTrue(issues.isEmpty, "Accessibility issues:\n" + issues.joined(separator: "\n"))
    }
}
