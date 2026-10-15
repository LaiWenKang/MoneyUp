import XCTest

/// Hiding amounts on a Today with a figure on every card: the pinned hero and
/// row, today's share and a payment due soon. The eye button only changes the
/// stored preference, so every figure on screen must follow it at once, and
/// VoiceOver must say "hidden amount", never read the mask aloud.
extension MoneyUpJourneyTests {
    func testHidingAmountsOnABudgetedTodayHidesAndSilencesEveryFigure() {
        // Journeys start with the shipped default, amounts hidden. A launch
        // argument would pin the preference, so the eye button drives it.
        let app = launch(extra: ["-MoneyUpUITestBudgetedBook"])
        let hero = app.descendants(matching: .any)["today-pinned-hero"]
        expectTrue(hero.waitForExistence(timeout: timeout), "The budgeted Today did not show its pinned hero")
        let show = app.navigationBars.buttons["Show amounts"]
        expectTrue(show.waitForExistence(timeout: timeout), "Today has no show-amounts button")
        show.tap()
        let hide = app.navigationBars.buttons["Hide amounts"]
        expectTrue(hide.waitForExistence(timeout: timeout), "Amounts did not show")
        let shown = Self.amounts(in: Self.settledTree(of: app))
        expectFalse(shown.isEmpty, "The budgeted Today shows no amounts to hide")

        hide.tap()
        expectTrue(show.waitForExistence(timeout: timeout), "Amounts did not hide")
        let tree = Self.settledTree(of: app)
        add(XCTAttachment(string: tree))
        let stillShown = shown.intersection(Self.amounts(in: tree))
        let readAloud = tree.split(separator: "\n").filter { $0.contains("*****") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        expectTrue(stillShown.isEmpty, "Still shown after hiding: \(stillShown.sorted().joined(separator: ", "))")
        expectTrue(readAloud.isEmpty, "VoiceOver would read the mask:\n" + readAloud.joined(separator: "\n"))
    }

    /// The element tree once a state change has had a moment to draw.
    private static func settledTree(of app: XCUIApplication) -> String {
        _ = app.activityIndicators.firstMatch.waitForNonExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 1)
        return app.debugDescription
    }

    /// Figures written with a decimal part (48.50, 551.50); dates and counts
    /// have none.
    private static func amounts(in tree: String) -> Set<String> {
        Set(tree.matches(of: /[0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2}/).map { String(tree[$0.range]) })
    }
}
