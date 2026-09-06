import XCTest
#if canImport(XCUIAutomation)
import XCUIAutomation
#endif

final class ColdOverviewLaunchTests: XCTestCase {
    @MainActor
    func testSmartOverviewColdLaunchRemainsInForeground() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.laiwenkang.MoneyUp")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        // XCUIApplication's URL launch drives the system handoff as a UI
        // action; bare simctl openurl can stop at an unanswered system prompt.
        app.open(try XCTUnwrap(URL(string: "moneyup://overview/today")))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "cold-smart-overview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
