import CoreGraphics
import Foundation
@testable import MoneyUp
import MoneyUpCore
import SwiftUI
import UIKit
import Vision
import XCTest

/// Log and the transaction editor at the largest text size on an iPhone
/// SE-width screen, in English and Simplified Chinese: the amount being
/// corrected, and the chosen account and category, show whole and are never
/// cut to "…". Read back from the pixels. Fictional data only.
final class FormValuesLargeTextRenderTests: XCTestCase {
    @MainActor
    func testLogAndTheEditorShowEveryChosenValueWholeAtTheLargestTextSize() async throws {
        let (fixture, model, expense) = try await makeFixture()
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
        for language in [AppLanguagePreference.english, .simplifiedChinese] {
            languageDefaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
            let hints = Self.fieldHints()
            let log = QuickLogEntryView(kind: .constant(.expense), dismissAfterSave: false, isActive: false,
                launchRequest: nil, onRequestHandled: { _ in }, onNavigate: { _ in }).environment(model)
            let logLines = await read(log, name: "form-values-log-\(language.rawValue)", language: language)
            problems += Self.cutValues(in: logLines, hints: hints).map { "log-\(language.rawValue): cut: \($0)" }

            let editor = TransactionEditView(entry: expense).environment(model)
            let editorLines = await read(editor, name: "form-values-editor-\(language.rawValue)", language: language)
            problems += Self.cutValues(in: editorLines, hints: hints).map { "editor-\(language.rawValue): cut: \($0)" }
            if !editorLines.contains(where: { HistoryLargeTextRenderTests.digits($0).contains("123456") }) {
                problems.append("editor-\(language.rawValue): the amount 1234.56 is not shown whole")
            }
            // The editor names the account and category only in their pickers.
            for value in ["Wallet", "Food", "Groceries"] where !editorLines.contains(where: { $0.contains(value) }) {
                problems.append("editor-\(language.rawValue): \(value) is not shown whole")
            }
        }
        XCTAssertEqual(problems, [], "Log and editor at AX5:\n" + problems.joined(separator: "\n"))
        await fixture.store.close()
    }

    func testCutValueDetectorKeepsHintsAndCatchesValues() {
        let hints = ["Description or notes (optional)", "e.g. lunch 12.50", "描述或备注（可选）"]
        XCTAssertEqual(Self.cutValues(in: ["Description...", "or notes (o...", "÷ e....", "描述或备…", "Wallet · SGD"],
                                      hints: hints), [])
        XCTAssertEqual(Self.cutValues(in: ["1234... SGD", "Cate- F...di", "…", "W…D"], hints: hints),
                       ["1234... SGD", "Cate- F...di", "…", "W…D"])
    }

    /// Lines cut short with an ellipsis, other than a field's hint: a long
    /// placeholder may end in "…" in a narrow field, a value never should.
    /// OCR splits a wrapped hint into lines, so a cut line counts as a hint
    /// when its words begin a hint, or the rest of one from any word on.
    static func cutValues(in lines: [String], hints: [String]) -> [String] {
        let beginnings = hints.flatMap { wordBeginnings(of: $0) }
        return lines.filter { line in
            guard let ellipsis = line.range(of: "…") ?? line.range(of: "...") else { return false }
            let words = searchable(String(line[..<ellipsis.lowerBound]))
            return words.isEmpty || !beginnings.contains { $0.hasPrefix(words) }
        }
    }

    /// The placeholder of each Log, editor and History search field, in the
    /// current language.
    static func fieldHints() -> [String] {
        ["transaction.description_or_notes", "transaction.title_or_merchant", "quick_log.smart_placeholder",
         "history.search"].map { AppLocalization.string($0) }
    }

    /// Reads a render far taller than a screen. Vision misses ordinary-size
    /// text in an image this tall, so it reads screen-shaped strips, each
    /// overlapping the next by half, and skips strips of plain background. A
    /// line is taken once, from a strip that holds it clear of a cut edge.
    /// Lines come top to bottom.
    static func readTallRender(_ image: UIImage, language: AppLanguagePreference) -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let width = cgImage.width, height = cgImage.height
        let strip = min(height, width * 2)
        var tops = Array(stride(from: 0, through: height - strip, by: max(strip / 2, 1)))
        if let last = tops.last, last + strip < height { tops.append(height - strip) }
        let inked = inkedRows(of: cgImage)
        let edge = 6.0
        var found: [(text: String, y: Double, x: Double)] = []
        for (index, top) in tops.enumerated() where inked[top..<(top + strip)].contains(true) {
            guard let piece = cgImage.cropping(to: CGRect(x: 0, y: top, width: width, height: strip)) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = language == .simplifiedChinese ? ["zh-Hans", "en-US"] : ["en-US"]
            try? VNImageRequestHandler(cgImage: piece).perform([request])
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                // Vision measures the box as a fraction of the strip, from its bottom.
                let box = observation.boundingBox
                let upper = Double(top) + (1 - Double(box.maxY)) * Double(strip)
                let lower = Double(top) + (1 - Double(box.minY)) * Double(strip)
                if index > 0, upper - Double(top) < edge { continue }
                if index < tops.count - 1, Double(top + strip) - lower < edge { continue }
                let middle = (upper + lower) / 2
                if found.contains(where: { $0.text == text && abs($0.y - middle) < 12 }) { continue }
                found.append((text, middle, Double(box.minX)))
            }
        }
        return found.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text)
    }

    /// The hint from each word on (each character, in Chinese), letters and
    /// digits only.
    private static func wordBeginnings(of hint: String) -> [String] {
        let characters = Array(hint)
        return characters.indices.compactMap { index in
            let startsWord = index == 0
                || !(characters[index - 1].isLetter || characters[index - 1].isNumber)
                || characters[index].unicodeScalars.contains { $0.properties.isIdeographic }
            return startsWord ? searchable(String(characters[index...])) : nil
        }
    }

    private static func searchable(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// For each row of pixels, top first, whether anything is drawn on it; a
    /// row of background is one colour edge to edge.
    private static func inkedRows(of image: CGImage) -> [Bool] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return Array(repeating: true, count: height) }
        return pixels.withUnsafeBufferPointer { bytes in
            (0..<height).map { row in
                var low: [UInt8] = [255, 255, 255], high: [UInt8] = [0, 0, 0]
                for column in stride(from: 0, to: width, by: 4) {
                    let offset = (row * width + column) * 4
                    for channel in 0..<3 {
                        low[channel] = min(low[channel], bytes[offset + channel])
                        high[channel] = max(high[channel], bytes[offset + channel])
                    }
                }
                return (0..<3).contains { high[$0] - low[$0] > 12 }
            }
        }
    }

    @MainActor
    private func read<Screen: View>(_ view: Screen, name: String, language: AppLanguagePreference) async -> [String] {
        let host = UIHostingController(rootView: view
            .environment(\.locale, Locale(identifier: language == .simplifiedChinese ? "zh-Hans" : "en_US"))
            .environment(\.dynamicTypeSize, .accessibility5)
            .tint(.accentColor))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 3_600)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let image = await LargeTextAmountRenderTests.settledLayerImage(of: host, scale: 2)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return Self.readTallRender(image, language: language)
    }

    /// One expense of 1,234.56 at Groceries, from Wallet (SGD), in Food; a USD
    /// account too, so account names carry their currency.
    @MainActor
    private func makeFixture() async throws -> (AppModelFixture, AppModel, JournalEntry) {
        let fixture = try AppModelFixture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T04:00:00Z"))
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food]
        let expense = try fixture.expense(amount: try XCTUnwrap(Decimal(string: "1234.56")), occurredAt: now,
            payee: "Groceries")
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
        try await fixture.seed(profile: profile, accounts: accounts, entries: [expense])
        let model = fixture.model(profile: profile, accounts: accounts, entries: [expense], currentDate: { now })
        return (fixture, model, expense)
    }
}
