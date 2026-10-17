import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import Vision
import XCTest

/// Release QA for settings a person combines: English and Simplified Chinese,
/// the default and the largest text size, the narrowest width (320 pt) and an
/// iPhone SE's (375 pt), amounts shown and then hidden on the same mounted
/// screen. Screens are rendered whole and read back from their pixels; a
/// hosted view builds no accessibility tree. Fictional data only.
final class ReleaseQARenderTests: XCTestCase {
    private static let languages: [AppLanguagePreference] = [.english, .simplifiedChinese]
    private static let sizes: [DynamicTypeSize] = [.large, .accessibility5]
    /// Every figure the fixture puts on Today or History; none may show once
    /// amounts are hidden.
    private static let figures = ["122,222.22", "123,456.78", "10,765.44", "1,234.56", "1234.56"]

    /// Today and History: every amount whole and with its currency, no raw
    /// string key, and nothing left showing after hiding amounts.
    @MainActor
    func testTodayAndHistoryStayWholeAndHideEveryFigureInBothLanguages() async throws {
        let (fixture, model, snapshot, _) = try await makeFixture()
        defer { fixture.removeFiles() }
        let restore = Self.preservePreferences()
        defer { restore() }
        var problems: [String] = []
        for language in Self.languages {
            AppLanguagePreference.defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
            for size in Self.sizes {
                for width in [320, 375] {
                    for (section, required) in [(MoneyUpSection.today, "122,222.22"), (.history, "1,234.56")] {
                        let name = "\(section)-\(language.rawValue)-\(size)-\(width)"
                        UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
                        let screen = MainTabView(initialReportingSnapshot: snapshot, initialSection: section)
                            .environment(model).environment(MoneyUpOverviewNavigation())
                        problems += await check(screen, name: name, language: language, size: size, width: width,
                                                shownMustInclude: required, amountsCarryCodes: true)
                    }
                }
            }
        }
        XCTAssertEqual(problems, [], "Release QA, Today and History:\n" + problems.joined(separator: "\n"))
        await fixture.store.close()
    }

    /// Log and the transaction editor at an iPhone SE's width: no raw string
    /// key in either language at either size, and the editor's amount hides.
    @MainActor
    func testLogAndTheEditorShowNoRawKeysAndTheEditorHidesItsAmount() async throws {
        let (fixture, model, _, expense) = try await makeFixture()
        defer { fixture.removeFiles() }
        let restore = Self.preservePreferences()
        defer { restore() }
        var problems: [String] = []
        for language in Self.languages {
            AppLanguagePreference.defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
            for size in Self.sizes {
                UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
                let log = QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false, isActive: false,
                    launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in }).environment(model)
                problems += await check(log, name: "log-\(language.rawValue)-\(size)", language: language,
                                        size: size, width: 375, shownMustInclude: nil, amountsCarryCodes: false)
                UserDefaults.standard.set(false, forKey: MoneyAmountPrivacy.storageKey)
                let editor = TransactionEditView(entry: expense).environment(model)
                problems += await check(editor, name: "editor-\(language.rawValue)-\(size)", language: language,
                                        size: size, width: 375, shownMustInclude: "1234.56", amountsCarryCodes: false)
            }
        }
        XCTAssertEqual(problems, [], "Release QA, Log and editor:\n" + problems.joined(separator: "\n"))
        await fixture.store.close()
    }

    func testRawKeyDetectorSeesKeysButNotWords() {
        XCTAssertEqual(Self.rawKeys(in: ["quick_log.amount", "支出 history.spent_headline_format"]).count, 2)
        XCTAssertEqual(Self.rawKeys(in: ["tab.today"]), ["tab.today"])
        XCTAssertEqual(Self.rawKeys(in: ["Today", "e.g. lunch 12", "SGD 1,234.56", "本月剩余", "github.com/x"]), [])
    }

    /// Renders `view` whole, reads it, hides amounts on the same mounted view,
    /// and reads it again. Returns what is wrong, named for the variant.
    @MainActor
    private func check<Screen: View>(
        _ view: Screen, name: String, language: AppLanguagePreference, size: DynamicTypeSize, width: Int,
        shownMustInclude required: String?, amountsCarryCodes: Bool
    ) async -> [String] {
        let host = UIHostingController(rootView: view
            .environment(\.locale, Locale(identifier: language == .simplifiedChinese ? "zh-Hans" : "en_US"))
            .environment(\.dynamicTypeSize, size)
            .tint(.accentColor))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
        // Tall enough for every row at the largest size; drawn from the layer
        // tree because a window this far past the screen is not composited.
        window.frame = CGRect(x: 0, y: 0, width: width, height: 3_600)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var problems: [String] = []
        let shownImage = await LargeTextAmountRenderTests.settledLayerImage(of: host, scale: 2)
        attach(shownImage, "release-qa-\(name)")
        let shown = Self.recognizedLines(in: shownImage, language: language)
        guard shown.count >= 4 else { return ["\(name): the render is blank"] }
        if amountsCarryCodes {
            problems += LargeTextAmountRenderTests.brokenAmounts(in: shown).map { "\(name): not whole: \($0)" }
        }
        if let required, !shown.contains(where: { $0.contains(required) }) {
            problems.append("\(name): \(required) is not shown whole")
        }
        problems += Self.rawKeys(in: shown).map { "\(name): raw key \($0)" }
        // The same write the eye button and a Focus filter make.
        UserDefaults.standard.set(true, forKey: MoneyAmountPrivacy.storageKey)
        let hiddenImage = await LargeTextAmountRenderTests.settledLayerImage(of: host, scale: 2)
        attach(hiddenImage, "release-qa-\(name)-hidden")
        let hidden = Self.recognizedLines(in: hiddenImage, language: language)
        guard hidden.count >= 4 else { return problems + ["\(name), hidden: the render is blank"] }
        let leaked = Self.figures.filter { figure in hidden.contains { $0.contains(figure) } }
        if !leaked.isEmpty { problems.append("\(name), hidden: still shows \(leaked.joined(separator: ", "))") }
        return problems
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A string-catalog key shown instead of its words: a whole line of
    /// dotted lowercase segments ("tab.today"), or dotted segments joined by
    /// underscores anywhere in a line ("quick_log.amount").
    static func rawKeys(in lines: [String]) -> [String] {
        lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.wholeMatch(of: /[a-z]+(?:\.[a-z0-9_]+)+/) != nil
                || line.contains(/[a-z]+(?:_[a-z0-9]+)+\.[a-z0-9_]+|[a-z]+\.[a-z0-9]+(?:_[a-z0-9]+)+/)
        }
    }

    static func recognizedLines(in image: UIImage, language: AppLanguagePreference) -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = language == .simplifiedChinese ? ["zh-Hans", "en-US"] : ["en-US"]
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private static func preservePreferences() -> () -> Void {
        let defaults = UserDefaults.standard
        let privacy = defaults.object(forKey: MoneyAmountPrivacy.storageKey)
        let languageDefaults = AppLanguagePreference.defaults
        let language = languageDefaults?.object(forKey: AppLanguagePreference.storageKey)
        return {
            if let privacy { defaults.set(privacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { defaults.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
            if let language { languageDefaults?.set(language, forKey: AppLanguagePreference.storageKey) }
            else { languageDefaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
    }

    /// A pinned Food budget of 12,000 with 1,234.56 spent from a wallet that
    /// received 123,456.78: cash 122,222.22, Food left 10,765.44.
    @MainActor
    private func makeFixture() async throws -> (AppModelFixture, AppModel, AppReportingSnapshot, JournalEntry) {
        let fixture = try AppModelFixture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let income = LedgerAccount(name: "Salary", kind: .income)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, income]
        let expense = try fixture.expense(amount: try XCTUnwrap(Decimal(string: "1234.56")), occurredAt: now,
            payee: "Groceries")
        let entries = try [
            TransactionFactory.income(
                amount: Money(try XCTUnwrap(Decimal(string: "123456.78")), currency: fixture.sgd),
                depositedInto: fixture.wallet.id, category: income.id,
                occurredAt: now.addingTimeInterval(-86_400 * 3), payee: "Salary"
            ),
            expense
        ]
        let nodes = [BudgetNode(id: fixture.food.id, name: "Food", limit: try Money(12_000, currency: fixture.sgd),
            purpose: .flexible)]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: calendar.timeZone.identifier,
            pinnedBudgetNodeIDs: [fixture.food.id])
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes)
        let model = fixture.model(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes,
            currentDate: { now })
        return (fixture, model, AppReportingSnapshot(instant: now, calendar: calendar), expense)
    }
}
