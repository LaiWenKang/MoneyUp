import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import XCTest

/// Build 1059.1 feedback: reviewed insights, the unfinished-entry signal, and
/// the shared state language. Screens are UIHostingController roots with
/// synthetic data; the images are review evidence, not device screenshots.
final class Feedback1059RenderEvidenceTests: XCTestCase {
    @MainActor
    func testRenderReviewedInsightsAndSharedStates() async throws {
        let fixture = try IntelligenceAppFixture()
        defer { fixture.removeFiles() }
        let previousPrivacy = UserDefaults.standard.object(forKey: MoneyAmountPrivacy.storageKey)
        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previousPrivacy { UserDefaults.standard.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
        }
        let profile = fixture.profile()
        let dates = fixture.weeklyDates
        var entries = try fixture.expenses(dates: dates, amount: 8, payee: "Weekly Cafe")
        entries += try fixture.expenses(dates: [dates[3]], amount: 8, payee: "Weekly Cafe")
        try await fixture.seed(profile: profile, entries: entries)
        // The reporting instant is the last logged day so Calendar shows flows.
        let now = dates[3].addingTimeInterval(3_600)
        let model = fixture.model(profile: profile, currentDate: { now })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "GMT"))
        let snapshot = AppReportingSnapshot(instant: now, calendar: calendar)

        model.refreshIntelligence()
        await model.waitForCurrentIntelligenceRefresh()
        XCTAssertFalse(model.intelligenceFindings.isEmpty)
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            await capture(NavigationStack { IntelligenceView() }.environment(model)
                .environment(\.appReportingSnapshot, snapshot).preferredColorScheme(scheme),
                name: "insights-findings-\(name)")
        }
        let first = try XCTUnwrap(model.intelligenceFindings.first)
        try await model.markIntelligenceFindingReviewed(first.id)
        XCTAssertEqual(model.reviewedIntelligenceFindings.map(\.id), [first.id])
        try await model.markAllIntelligenceFindingsReviewed()
        XCTAssertTrue(model.intelligenceFindings.isEmpty)
        await capture(NavigationStack { IntelligenceView() }.environment(model)
            .environment(\.appReportingSnapshot, snapshot).preferredColorScheme(.light), name: "insights-all-reviewed")
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .today).environment(model)
            .environment(MoneyUpOverviewNavigation()).preferredColorScheme(.light), name: "today-quiet-insights")

        // A blank Log visit leaves a routing-only draft: History must not
        // announce an unfinished entry for it.
        var blank = QuickLogDraft(kind: .income, amountText: "", destinationAmountText: "", accountID: fixture.account.id,
            destinationAccountID: nil, categoryID: nil, occurredAt: now, dateWasEdited: false, payee: "", note: "", smartText: "")
        blank.smartState.edited(.kind)
        model.quickLogDraft = blank
        XCTAssertFalse(blank.hasUserEdits)
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .history).environment(model)
            .environment(MoneyUpOverviewNavigation()).preferredColorScheme(.light), name: "history-no-unfinished-banner")
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .log).environment(model)
            .environment(MoneyUpOverviewNavigation()).preferredColorScheme(.dark), name: "log-smart-entry-copy")

        // Recent-entry capsules, rendered directly so the evidence does not
        // depend on the debounced lookup finishing inside the capture window.
        let preloads = await model.historyPreloadSuggestions(
            for: CaptureSuggestionQuery(kind: .expense, payee: "", currency: fixture.currency, occurredAt: now),
            eligibleCategoryIDs: [fixture.category.id, fixture.categoryTwo.id]
        ).merchants
        XCTAssertFalse(preloads.isEmpty, "Weekly Cafe should be offered as a recent entry")
        await capture(
            VStack(alignment: .leading, spacing: 8) {
                Label("quick_log.preload_title", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(preloads) { suggestion in
                            HistoryPreloadChip(suggestion: suggestion, categoryName: "Food",
                                available: QuickLogHistoryPreloadFill.fields, canApplyAll: true) { _ in }
                        }
                    }
                }
            }
            .padding().background(Color.moneyUpBackground).environment(model).preferredColorScheme(.light),
            name: "log-recent-capsules", height: 160
        )
        await capture(MainTabView(initialReportingSnapshot: snapshot, initialSection: .plan, initialPlanSection: .calendar)
            .environment(model).environment(MoneyUpOverviewNavigation()).preferredColorScheme(.light), name: "calendar-flow-bars")
        await capture(NavigationStack { SavingsGoalsView() }.environment(model).environment(\.appReportingSnapshot, snapshot)
            .preferredColorScheme(.dark), name: "goals-empty-state")
        await capture(NavigationStack { LoanCenterView() }.environment(model).environment(\.appReportingSnapshot, snapshot)
            .preferredColorScheme(.light), name: "loans-empty-state")
        await capture(NavigationStack { AllowanceCenterView() }.environment(model).environment(\.appReportingSnapshot, snapshot)
            .preferredColorScheme(.dark), name: "allowances-empty-state")
        await capture(NavigationStack { ExchangeRatesView() }.environment(model).environment(\.appReportingSnapshot, snapshot)
            .preferredColorScheme(.light), name: "rates-empty-state")
        await capture(NavigationStack { IntelligenceView() }.environment(model).environment(\.appReportingSnapshot, snapshot)
            .environment(\.dynamicTypeSize, .accessibility2).preferredColorScheme(.light), name: "insights-large-text", height: 1100)
        await fixture.store.close()
    }

    @MainActor
    @discardableResult
    private func capture<Content: View>(
        _ content: Content, name: String, width: CGFloat = 390, height: CGFloat = 844
    ) async -> UIImage {
        let controller = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: "en")))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(900))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}
