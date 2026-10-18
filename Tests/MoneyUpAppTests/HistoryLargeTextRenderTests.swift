import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import Vision
import XCTest

/// History at the largest text size, on a 320 pt and an iPhone SE-width
/// screen, in English and Simplified Chinese: the range keeps its name whole
/// on one line, and every amount keeps its currency code on its line. Read
/// back from the pixels. Fictional data only.
final class HistoryLargeTextRenderTests: XCTestCase {
    @MainActor
    func testHistoryKeepsTheRangeNameAndEveryAmountWholeAtTheLargestTextSize() async throws {
        try FormValuesLargeTextRenderTests.skipTallRenderWhereNotComposited()
        let (fixture, model, snapshot) = try await makeFixture()
        defer { fixture.removeFiles() }
        let defaults = UserDefaults.standard
        let previousPrivacy = defaults.object(forKey: MoneyAmountPrivacy.storageKey)
        let languageDefaults = AppLanguagePreference.defaults
        let previousLanguage = languageDefaults?.object(forKey: AppLanguagePreference.storageKey)
        defaults.set(false, forKey: MoneyAmountPrivacy.storageKey)
        defer {
            if let previousPrivacy { defaults.set(previousPrivacy, forKey: MoneyAmountPrivacy.storageKey) }
            else { defaults.removeObject(forKey: MoneyAmountPrivacy.storageKey) }
            if let previousLanguage { languageDefaults?.set(previousLanguage, forKey: AppLanguagePreference.storageKey) }
            else { languageDefaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        var problems: [String] = []
        for (language, range) in [(AppLanguagePreference.english, "Today"), (.simplifiedChinese, "今天")] {
            languageDefaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
            for width in [320, 375] {
                let name = "\(language.rawValue)-\(width)"
                let host = UIHostingController(rootView: MainTabView(initialReportingSnapshot: snapshot, initialSection: .history)
                    .environment(model).environment(MoneyUpOverviewNavigation())
                    .environment(\.locale, Locale(identifier: language == .simplifiedChinese ? "zh-Hans" : "en_US"))
                    .environment(\.dynamicTypeSize, .accessibility5)
                    .tint(.accentColor))
                let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                    .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 3_600)
                window.rootViewController = host
                window.isHidden = false
                host.view.frame = window.bounds
                let image = await LargeTextAmountRenderTests.settledLayerImage(of: host, scale: 2)
                let attachment = XCTAttachment(image: image)
                attachment.name = "history-ax5-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let lines = Self.recognizedLines(in: image, language: language)
                window.isHidden = true
                window.rootViewController = nil
                guard lines.count >= 4 else {
                    problems.append("\(name): the render is blank")
                    continue
                }
                if !lines.contains(where: { $0.contains(range) }) {
                    problems.append("\(name): the range name \(range) is not whole on a line: \(lines.prefix(8))")
                }
                problems += Self.amountsWithoutTheirCode(in: lines).map { "\(name): \($0) is apart from its code" }
                if !lines.contains(where: { Self.digits($0).contains("123456") }) {
                    problems.append("\(name): 1,234.56 is not shown whole")
                }
            }
        }
        XCTAssertEqual(problems, [], "History at AX5:\n" + problems.joined(separator: "\n"))
        await fixture.store.close()
    }

    func testAmountDetectorToleratesMisreadCodesButNotBareFigures() {
        XCTAssertEqual(Self.amountsWithoutTheirCode(in: ["SGD 1,234.56", "sGD 10,765.44", "S6D 10,765.44"]), [])
        XCTAssertEqual(Self.amountsWithoutTheirCode(in: ["SGD", "1,234.56"]), ["1,234.56"])
        XCTAssertEqual(Self.amountsWithoutTheirCode(in: ["支出 SGD1,234.56", "12:00 · Food"]), [])
    }

    /// Lines holding a figure with a decimal part but no currency code before
    /// it. OCR sometimes reads "SGD" as "sGD" or "S6D", so any three letters
    /// or digits that include a letter count as the code.
    static func amountsWithoutTheirCode(in lines: [String]) -> [String] {
        lines.filter { line in
            line.contains(/[0-9]+\.[0-9]{2}/)
                && !line.contains(/(?:[A-Za-z][A-Za-z0-9]{2}|[A-Za-z0-9][A-Za-z][A-Za-z0-9]|[A-Za-z0-9]{2}[A-Za-z])\s?[0-9]/)
        }
    }

    static func digits(_ line: String) -> String {
        String(line.filter(\.isNumber))
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

    /// One expense of 1,234.56 today, so History's default range lists it.
    @MainActor
    private func makeFixture() async throws -> (AppModelFixture, AppModel, AppReportingSnapshot) {
        let fixture = try AppModelFixture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food]
        let entries = try [fixture.expense(amount: try XCTUnwrap(Decimal(string: "1234.56")), occurredAt: now,
            payee: "Groceries")]
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: calendar.timeZone.identifier)
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries)
        let model = fixture.model(profile: profile, accounts: accounts, entries: entries, currentDate: { now })
        return (fixture, model, AppReportingSnapshot(instant: now, calendar: calendar))
    }
}
