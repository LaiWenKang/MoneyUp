import XCTest

/// The reminders screen driven the way a person uses it: turn a kind on,
/// choose when, and see Settings follow. iOS asks for notification permission
/// the first time a reminder is turned on, so these journeys answer it too.
extension MoneyUpJourneyTests {
    // MARK: Helpers

    /// A simulator that already answered never shows the prompt, so this only
    /// waits for it briefly.
    func allowNotificationsIfAsked(waiting seconds: TimeInterval = 4) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
        if allow.waitForExistence(timeout: seconds) { allow.tap() }
    }

    func anyElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// What VoiceOver would say about an element: its label, then its value.
    func spoken(_ element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
    }

    func waitUntil(_ seconds: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let never = XCTestExpectation(description: "pause")
        never.isInverted = true
        _ = XCTWaiter().wait(for: [never], timeout: seconds)
    }

    /// Scrolls the reminders form, in whichever direction the element lies,
    /// until it can be tapped. A fling carries the form a fixed distance, so a
    /// row that lies between two of its resting places is never loaded and a
    /// search by flings can miss it for ever. A row that is not loaded is
    /// therefore looked for a controlled page at a time: a little way down,
    /// then far up, then far down.
    func reveal(_ element: XCUIElement, in app: XCUIApplication,
                file: StaticString = #filePath, line: UInt = #line) {
        func inView() -> Bool { element.exists && element.isHittable }
        var sweeps: [(towardsTop: Bool, pages: Int)] = [(false, 6), (true, 12), (false, 12)]
        var sweep = 0
        var pagesInSweep = 0
        var steps = 0
        var flungDown: Bool?
        while !inView() && steps < 40 {
            steps += 1
            if element.exists {
                let towardsTop = element.frame.midY < app.frame.midY
                if towardsTop { app.swipeDown() } else { app.swipeUp() }
                flungDown = !towardsTop
            } else {
                if let passed = flungDown {
                    sweeps = [(passed, 12), (!passed, 24)]
                    sweep = 0
                    pagesInSweep = 0
                    flungDown = nil
                }
                if pagesInSweep >= sweeps[sweep].pages {
                    sweep = min(sweep + 1, sweeps.count - 1)
                    pagesInSweep = 0
                }
                searchFormPage(app, towardsTop: sweeps[sweep].towardsTop)
                pagesInSweep += 1
            }
        }
        if !inView() { printScreen(app) }
        expectTrue(inView(), "Could not bring \(element) into view", file: file, line: line)
    }

    /// Turns a switch on or off by its knob and waits for it to settle.
    func flip(_ toggle: XCUIElement, in app: XCUIApplication, to on: Bool,
              file: StaticString = #filePath, line: UInt = #line) {
        reveal(toggle, in: app, file: file, line: line)
        let wanted = on ? "1" : "0"
        if toggle.value as? String == wanted { return }
        let knob = toggle.switches.firstMatch
        if knob.exists {
            knob.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        expectTrue(waitUntil { toggle.value as? String == wanted },
                   "The switch did not turn \(on ? "on" : "off"): \(toggle)", file: file, line: line)
    }

    func expectSwitch(_ identifier: String, is expected: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches[identifier]
        reveal(toggle, in: app, file: file, line: line)
        _ = waitUntil(5) { toggle.value as? String == expected }
        expectEqual(toggle.value as? String, expected, "\(identifier) did not keep its choice", file: file, line: line)
    }

    func expectChoice(_ identifier: String, selected: Bool, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons[identifier]
        reveal(row, in: app, file: file, line: line)
        _ = waitUntil(5) { row.isSelected == selected }
        expectEqual(row.isSelected, selected, "\(identifier) did not keep its choice", file: file, line: line)
    }

    /// Opens Settings and brings the reminders row into view.
    func reminderRow(_ app: XCUIApplication, settings: String = "Settings",
                     file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        openSettings(app, label: settings, file: file, line: line)
        let entry = app.buttons["settings-reminders"]
        scrollTo(entry, in: app, maxSwipes: 20)
        expectTrue(entry.waitForExistence(timeout: timeout), "Settings has no reminders row", file: file, line: line)
        return entry
    }

    func enterReminders(_ entry: XCUIElement, _ app: XCUIApplication, title: String = "Reminders",
                        file: StaticString = #filePath, line: UInt = #line) {
        entry.tap()
        expectTrue(app.navigationBars[title].waitForExistence(timeout: timeout),
                   "The reminders screen did not open", file: file, line: line)
    }

    func leaveReminders(_ app: XCUIApplication, title: String = "Reminders") {
        app.navigationBars[title].buttons.element(boundBy: 0).tap()
    }

    /// Payments and income, the daily reminder with a second time, and the
    /// weekly review: three kinds on, so every row is somewhere on the form.
    func turnEveryReminderOn(_ app: XCUIApplication) {
        flip(app.switches["settings-reminders-bills"], in: app, to: true)
        allowNotificationsIfAsked(waiting: 6)
        flip(app.switches["settings-reminders-daily"], in: app, to: true)
        let add = app.buttons["settings-reminders-add-time"]
        reveal(add, in: app)
        add.tap()
        flip(app.switches["settings-reminders-weekly"], in: app, to: true)
    }

    /// Moves the form about two fifths of a screen and stops dead. A swipe
    /// flings past whole rows; this keeps every row on two consecutive pages.
    private func scrollFormPage(_ app: XCUIApplication, towardsTop: Bool = false) {
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let (from, to) = towardsTop ? (low, high) : (high, low)
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    /// Moves the form about seven tenths of a screen and stops dead, faster
    /// than `scrollFormPage`, for looking for a row rather than auditing it.
    private func searchFormPage(_ app: XCUIApplication, towardsTop: Bool) {
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let (from, to) = towardsTop ? (low, high) : (high, low)
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    /// Audits the reminders form from its top to its bottom, one overlapping
    /// screenful at a time, since a form only holds the rows near the screen.
    func auditReminders(_ app: XCUIApplication, _ types: XCUIAccessibilityAuditType,
                        screen: String) throws -> [String] {
        let first = app.switches["settings-reminders-bills"]
        var swipes = 0
        while !(first.exists && first.isHittable) && swipes < 16 { app.swipeDown(); swipes += 1 }
        var issues = try auditPage(app, types, screen: screen, page: 0)
        let last = app.buttons["settings-reminders-test"]
        var pages = 0
        while !(last.exists && last.isHittable) && pages < 40 {
            scrollFormPage(app)
            pages += 1
            issues += try auditPage(app, types, screen: screen, page: pages)
        }
        expectTrue(last.exists && last.isHittable, "The audit never reached the last row of the form")
        return issues
    }

    /// One screenful of the form; a page with findings keeps a picture of it.
    private func auditPage(_ app: XCUIApplication, _ types: XCUIAccessibilityAuditType,
                           screen: String, page: Int) throws -> [String] {
        let found = try auditIssues(app, types, screen: "\(screen) page \(page)")
        if !found.isEmpty { attachScreenshot(app, "audit-\(screen)-page-\(page)") }
        return found
    }

    /// Static texts of twenty letters or more, with their height. At the largest text size such
    /// words cannot fit on one line, so the height of one line means they were cut off.
    private func longLabels(_ app: XCUIApplication) -> [(text: String, height: CGFloat)] {
        let long = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".{20,}"))
        return long.allElementsBoundByIndex.map { ($0.label, $0.frame.height) }
    }

    /// Pictures the form at chosen rows and returns every long label cut to one line. The clipping
    /// audit only reports: it flagged wrapped rows in one run and missed a row cut on purpose in most.
    func checkReminderStops(_ app: XCUIApplication, _ types: XCUIAccessibilityAuditType,
                            screen: String, stops: [String]) throws -> [String] {
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
        let between = CGRect(x: 0, y: top, width: app.frame.width, height: bottom - top)
        var cutOff: [String] = []
        var measured: [String] = []
        var reported: [String] = []
        for stop in stops {
            let name = "\(screen) at \(stop)"
            let element = anyElement(stop, in: app)
            reveal(element, in: app)
            expectTrue(element.frame.minX >= -0.5 && element.frame.maxX <= app.frame.width + 0.5,
                       "\(stop) runs off the side of the screen: \(element.frame)")
            attachScreenshot(app, "audit-\(name)")
            let long = longLabels(app)
            measured += long.map { "\(name): '\($0.text)' \($0.height) pt" }
            cutOff += long.filter { $0.height > 0 && $0.height < 70 }
                .map { "\(name): cut to one line — '\($0.text)' \($0.height) pt" }
            reported += try auditIssues(app, types, screen: name, skippingUnlocated: true, within: between)
        }
        keep(measured, as: "audit-long-labels")
        keep(reported, as: "audit-findings-\(screen)")
        expectTrue(measured.count >= stops.count / 2,
                   "The long-label check measured only \(measured.count) labels, so it may not see the form")
        return cutOff
    }

    private func keep(_ lines: [String], as name: String) {
        let note = XCTAttachment(string: lines.joined(separator: "\n"))
        note.name = name
        note.lifetime = .keepAlways
        add(note)
    }

    // MARK: Journeys

    func testRemindersAreChosenOnOneScreenAndSettingsFollows() {
        let app = launch()
        let entry = reminderRow(app)
        expectTrue(spoken(entry).contains("Off"), "Every reminder starts off: \(spoken(entry))")
        enterReminders(entry, app)
        expectFalse(app.buttons["settings-reminders-lead-0"].exists, "Lead days show before payments are on")
        expectFalse(app.buttons["settings-reminders-add-time"].exists, "A second time shows before the daily reminder is on")

        // Scheduled payments and income: choose how far ahead.
        flip(app.switches["settings-reminders-bills"], in: app, to: true)
        allowNotificationsIfAsked(waiting: 6)
        let sameDay = app.buttons["settings-reminders-lead-0"]
        let threeDays = app.buttons["settings-reminders-lead-3"]
        expectTrue(sameDay.waitForExistence(timeout: timeout), "Lead days did not appear once payments were on")
        expectTrue(sameDay.isSelected, "A reminder on the day is where it starts")
        reveal(threeDays, in: app)
        threeDays.tap()
        eventually("isSelected == true", threeDays, "3 days before did not turn on")
        attachScreenshot(app, "journey-reminders-payments")
        reveal(sameDay, in: app)
        sameDay.tap()
        eventually("isSelected == false", sameDay, "On the day did not turn off")
        reveal(threeDays, in: app)
        threeDays.tap()
        expectTrue(threeDays.isSelected, "The last lead day must stay on")
        flip(app.switches["settings-reminders-income"], in: app, to: false)

        // Weekly review: the day comes from a menu. This runs before the daily
        // days are on, because those rows carry the same day names.
        flip(app.switches["settings-reminders-weekly"], in: app, to: true)
        let weeklyDay = anyElement("settings-reminders-weekly-day", in: app)
        reveal(weeklyDay, in: app)
        weeklyDay.tap()
        let friday = app.buttons["Friday"]
        expectTrue(friday.waitForExistence(timeout: timeout), "The weekly day list did not open")
        friday.tap()
        if !app.navigationBars["Reminders"].waitForExistence(timeout: 2) {
            app.navigationBars.buttons.firstMatch.tap()
        }
        expectTrue(waitUntil { spoken(weeklyDay).contains("Friday") },
                   "The weekly review did not move to Friday: \(spoken(weeklyDay))")

        // Daily reminder: up to three times a day, on the days chosen.
        flip(app.switches["settings-reminders-daily"], in: app, to: true)
        let add = app.buttons["settings-reminders-add-time"]
        reveal(add, in: app)
        add.tap()
        expectTrue(app.buttons["settings-reminders-remove-time-1"].waitForExistence(timeout: timeout),
                   "A second daily time did not appear")
        expectTrue(app.buttons["settings-reminders-remove-time-0"].exists, "With two times, either can go")
        reveal(add, in: app)
        add.tap()
        expectTrue(app.buttons["settings-reminders-remove-time-2"].waitForExistence(timeout: timeout),
                   "A third daily time did not appear")
        expectTrue(add.waitForNonExistence(timeout: timeout), "Three times a day is the most")
        let removeSecond = app.buttons["settings-reminders-remove-time-1"]
        reveal(removeSecond, in: app)
        removeSecond.tap()
        expectTrue(app.buttons["settings-reminders-remove-time-2"].waitForNonExistence(timeout: timeout),
                   "The time was not removed")
        expectTrue(add.waitForExistence(timeout: timeout), "Add did not come back after a time went")
        let monday = app.buttons["settings-reminders-weekday-2"]
        reveal(monday, in: app)
        expectTrue(monday.isSelected, "Every day starts on")
        monday.tap()
        eventually("isSelected == false", monday, "Monday did not turn off")
        flip(app.switches["settings-reminders-skip-logged"], in: app, to: false)

        // How they arrive.
        flip(app.switches["settings-reminders-details"], in: app, to: true)
        flip(app.switches["settings-reminders-sound"], in: app, to: false)
        attachScreenshot(app, "journey-reminders-how-they-arrive")

        // Settings shows three kinds on, and the choices are still there.
        leaveReminders(app)
        expectTrue(entry.waitForExistence(timeout: timeout), "Back did not return to Settings")
        expectTrue(waitUntil { spoken(entry).contains("3 on") }, "Settings should say 3 on: \(spoken(entry))")
        enterReminders(entry, app)
        expectSwitch("settings-reminders-bills", is: "1", in: app)
        expectSwitch("settings-reminders-income", is: "0", in: app)
        expectChoice("settings-reminders-lead-3", selected: true, in: app)
        expectChoice("settings-reminders-lead-0", selected: false, in: app)
        expectSwitch("settings-reminders-daily", is: "1", in: app)
        expectChoice("settings-reminders-weekday-2", selected: false, in: app)
        expectChoice("settings-reminders-weekday-3", selected: true, in: app)
        expectSwitch("settings-reminders-skip-logged", is: "0", in: app)
        expectSwitch("settings-reminders-weekly", is: "1", in: app)
        expectTrue(spoken(anyElement("settings-reminders-weekly-day", in: app)).contains("Friday"),
                   "The weekly review forgot Friday")
        expectSwitch("settings-reminders-details", is: "1", in: app)
        expectSwitch("settings-reminders-sound", is: "0", in: app)

        // A test reminder: it says it was sent and arrives while the app is open.
        let test = app.buttons["settings-reminders-test"]
        reveal(test, in: app)
        expectTrue(test.isEnabled, "Notifications are allowed, so the test reminder must be available")
        test.tap()
        let sentAt = Date()
        allowNotificationsIfAsked(waiting: 1)
        expectTrue(app.staticTexts["settings-reminders-test-sent"].waitForExistence(timeout: timeout),
                   "Sending a test reminder gave no confirmation")
        attachScreenshot(app, "journey-reminders-test-sent")

        // Everything off again, and Settings says so.
        flip(app.switches["settings-reminders-weekly"], in: app, to: false)
        flip(app.switches["settings-reminders-daily"], in: app, to: false)
        flip(app.switches["settings-reminders-bills"], in: app, to: false)
        // The test arrives about five seconds after it was sent and stays a few
        // seconds over the top of the screen; wait it out before going back.
        pause(12 - Date().timeIntervalSince(sentAt))
        expectTrue(app.state == .runningForeground, "MoneyUp stopped while a reminder arrived")
        leaveReminders(app)
        expectTrue(entry.waitForExistence(timeout: timeout), "Back did not return to Settings")
        expectTrue(waitUntil { spoken(entry).contains("Off") }, "Settings should say Off again: \(spoken(entry))")
    }

    func testRemindersReadInSimplifiedChinese() {
        let app = launch(language: "zh-Hans")
        let entry = reminderRow(app, settings: "设置")
        expectTrue(spoken(entry).contains("关闭"), "Every reminder starts off: \(spoken(entry))")
        enterReminders(entry, app, title: "提醒")
        flip(app.switches["settings-reminders-bills"], in: app, to: true)
        allowNotificationsIfAsked(waiting: 6)
        let dayBefore = app.buttons["settings-reminders-lead-1"]
        expectTrue(dayBefore.waitForExistence(timeout: timeout), "Lead days did not appear once payments were on")
        expectTrue(spoken(dayBefore).contains("提前 1 天"), "Lead days should read in Chinese: \(spoken(dayBefore))")
        attachScreenshot(app, "journey-zh-reminders")
        flip(app.switches["settings-reminders-weekly"], in: app, to: true)
        attachScreenshot(app, "journey-zh-reminders-weekly")
        leaveReminders(app, title: "提醒")
        expectTrue(entry.waitForExistence(timeout: timeout), "Back did not return to Settings")
        expectTrue(waitUntil { spoken(entry).contains("已开启 2 项") }, "Settings should say 2 on: \(spoken(entry))")
    }

    func testAccessibilityAuditOfTheRemindersScreen() throws {
        let app = launch()
        enterReminders(reminderRow(app), app)
        turnEveryReminderOn(app)
        let issues = try auditReminders(app, [.sufficientElementDescription, .hitRegion, .trait], screen: "Reminders")
        add(XCTAttachment(string: issues.joined(separator: "\n")))
        expectTrue(issues.isEmpty, "Accessibility issues:\n" + issues.joined(separator: "\n"))
    }

    func testLargestAccessibilityTextSizeKeepsRemindersReadable() throws {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        enterReminders(reminderRow(app), app)
        turnEveryReminderOn(app)
        attachScreenshot(app, "journey-ax5-reminders")
        // This row once ran to one shortened line, which the clipping audit did not see.
        reveal(app.buttons["settings-reminders-add-time"], in: app)
        let addTime = app.staticTexts["Add another time"]
        expectTrue(addTime.exists && addTime.frame.height > 90,
                   "Add another time is cut to one line at AX5: \(addTime.exists ? "\(addTime.frame)" : "missing")")
        let cutOff = try checkReminderStops(app, [.textClipped], screen: "Reminders AX5", stops: [
            "settings-reminders-bills", "settings-reminders-lead-2", "settings-reminders-remove-time-1",
            "settings-reminders-weekday-4", "settings-reminders-weekly-day", "settings-reminders-snooze",
            "settings-reminders-test"
        ])
        expectTrue(cutOff.isEmpty, "Cut-off text at AX5:\n" + cutOff.joined(separator: "\n"))
    }
}
