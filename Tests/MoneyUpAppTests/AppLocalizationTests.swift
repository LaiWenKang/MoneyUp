import Foundation
@testable import MoneyUp
import XCTest

final class AppLocalizationTests: XCTestCase {
    private var originalLanguage: String?

    override func setUp() {
        super.setUp()
        originalLanguage = AppLanguagePreference.defaults.string(
            forKey: AppLanguagePreference.storageKey
        )
    }

    override func tearDown() {
        if let originalLanguage {
            AppLanguagePreference.defaults.set(
                originalLanguage,
                forKey: AppLanguagePreference.storageKey
            )
        } else {
            AppLanguagePreference.defaults.removeObject(
                forKey: AppLanguagePreference.storageKey
            )
        }
        super.tearDown()
    }

    func testProgrammaticLocalizationFollowsEnglishPreference() {
        AppLanguagePreference.defaults.set(
            AppLanguagePreference.english.rawValue,
            forKey: AppLanguagePreference.storageKey
        )

        XCTAssertEqual(AppLocalization.string("settings.title"), "Settings")
    }

    func testProgrammaticLocalizationFollowsSimplifiedChinesePreference() {
        AppLanguagePreference.defaults.set(
            AppLanguagePreference.simplifiedChinese.rawValue,
            forKey: AppLanguagePreference.storageKey
        )

        XCTAssertEqual(AppLocalization.string("settings.title"), "设置")
    }

    func testUnknownStoredLanguageFallsBackToSystem() {
        AppLanguagePreference.defaults.set(
            "unsupported-language",
            forKey: AppLanguagePreference.storageKey
        )

        XCTAssertEqual(AppLanguagePreference.current, .system)
    }

    func testVersion070DeclaresBilingualReleaseHighlights() {
        XCTAssertEqual(ReleaseNotes.highlights(for: "0.7.0").count, 5)

        for key in [
            "whats_new.0_7_0.intelligence",
            "whats_new.0_7_0.projections",
            "whats_new.0_7_0.language",
            "whats_new.0_7_0.details",
            "whats_new.0_7_0.privacy"
        ] {
            AppLanguagePreference.defaults.set(
                AppLanguagePreference.english.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)

            AppLanguagePreference.defaults.set(
                AppLanguagePreference.simplifiedChinese.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)
        }
    }

    func testVersion071DeclaresBilingualReleaseHighlights() {
        XCTAssertEqual(ReleaseNotes.highlights(for: "0.7.1").count, 5)

        for key in [
            "whats_new.0_7_1.logging",
            "whats_new.0_7_1.history",
            "whats_new.0_7_1.loans",
            "whats_new.0_7_1.planning",
            "whats_new.0_7_1.categories"
        ] {
            AppLanguagePreference.defaults.set(
                AppLanguagePreference.english.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)

            AppLanguagePreference.defaults.set(
                AppLanguagePreference.simplifiedChinese.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)
        }
    }
}
