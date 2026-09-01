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
}
