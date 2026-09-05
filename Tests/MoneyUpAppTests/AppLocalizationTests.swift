import Foundation
@testable import MoneyUp
import XCTest

final class AppLocalizationTests: XCTestCase {
    private var originalLanguage: String?

    private var languageDefaults: UserDefaults {
        guard let defaults = AppLanguagePreference.defaults else {
            fatalError("App Group defaults unavailable in localization tests")
        }
        return defaults
    }

    override func setUp() {
        super.setUp()
        originalLanguage = languageDefaults.string(
            forKey: AppLanguagePreference.storageKey
        )
    }

    override func tearDown() {
        if let originalLanguage {
            languageDefaults.set(
                originalLanguage,
                forKey: AppLanguagePreference.storageKey
            )
        } else {
            languageDefaults.removeObject(
                forKey: AppLanguagePreference.storageKey
            )
        }
        super.tearDown()
    }

    func testProgrammaticLocalizationFollowsEnglishPreference() {
        languageDefaults.set(
            AppLanguagePreference.english.rawValue,
            forKey: AppLanguagePreference.storageKey
        )

        XCTAssertEqual(AppLocalization.string("settings.title"), "Settings")
    }

    func testProgrammaticLocalizationFollowsSimplifiedChinesePreference() {
        languageDefaults.set(
            AppLanguagePreference.simplifiedChinese.rawValue,
            forKey: AppLanguagePreference.storageKey
        )

        XCTAssertEqual(AppLocalization.string("settings.title"), "设置")
    }

    func testUnknownStoredLanguageFallsBackToSystem() {
        languageDefaults.set(
            "unsupported-language",
            forKey: AppLanguagePreference.storageKey
        )

        XCTAssertEqual(AppLanguagePreference.current, .system)
    }

    func testUnavailableSharedDefaultsFallsBackToSystemLanguage() {
        XCTAssertEqual(AppLanguagePreference.resolved(from: nil), .system)
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
            languageDefaults.set(
                AppLanguagePreference.english.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)

            languageDefaults.set(
                AppLanguagePreference.simplifiedChinese.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)
        }
    }

    func testVersion071DeclaresBilingualReleaseHighlights() {
        XCTAssertEqual(ReleaseNotes.highlights(for: "0.7.1").count, 6)

        for key in [
            "whats_new.0_7_1.logging",
            "whats_new.0_7_1.history",
            "whats_new.0_7_1.loans",
            "whats_new.0_7_1.planning",
            "whats_new.0_7_1.categories",
            "whats_new.0_7_1.widget"
        ] {
            languageDefaults.set(
                AppLanguagePreference.english.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)

            languageDefaults.set(
                AppLanguagePreference.simplifiedChinese.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)
        }
    }

    func testNavigationAndCategoryFilterCopyIsBilingual() {
        for key in [
            "plan.section_picker",
            "history.back_to_format",
            "history.filter.category_count",
            "history.filter.category_hint",
            "history.filter.clear_category",
            "history.filter.more_categories"
        ] {
            languageDefaults.set(
                AppLanguagePreference.english.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)

            languageDefaults.set(
                AppLanguagePreference.simplifiedChinese.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertNotEqual(AppLocalization.string(key), key)
        }
    }

    func testWidgetConsentCopyMatchesTheBoundedRecordFreePayload() {
        let expectations: [(
            language: AppLanguagePreference,
            title: String,
            required: [String],
            forbidden: [String]
        )] = [
            (
                .english,
                "Allow widget summaries",
                [
                    "budget-plan status",
                    "rounded budget and allowance percentages",
                    "bounded review and expense-commitment counts",
                    "reporting-calendar day distance"
                ],
                ["percentage-only", "next due time"]
            ),
            (
                .simplifiedChinese,
                "允许小组件摘要",
                ["预算规划状态", "取整后的预算与津贴百分比", "有上限的待复核数量和支出承诺数量", "按报表日历计算"],
                ["仅含百分比", "下次到期时间"]
            )
        ]

        for expectation in expectations {
            languageDefaults.set(
                expectation.language.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            XCTAssertEqual(
                AppLocalization.string("settings.widget.budget_status"),
                expectation.title
            )
            let consent = [
                AppLocalization.string("settings.widget.budget_status_detail"),
                AppLocalization.string("settings.widget.budget_status_hint")
            ].joined(separator: " ")
            expectation.required.forEach {
                XCTAssertTrue(consent.contains($0), "Missing widget consent copy: \($0)")
            }
            expectation.forbidden.forEach {
                XCTAssertFalse(consent.contains($0), "Stale widget consent copy: \($0)")
            }
        }
    }

    func testQuickActionAccessibilityHintsStayPreferenceNeutral() {
        XCTAssertFalse(MoneyUpQuickAction.expense.requiresUnlock)
        XCTAssertTrue(MoneyUpQuickAction.smartEntry.requiresUnlock)
        let expectations: [(
            language: AppLanguagePreference,
            capture: String,
            unlock: String,
            forbidden: String
        )] = [
            (
                .english,
                "Open MoneyUp to continue logging",
                "Unlock required",
                "without unlocking"
            ),
            (
                .simplifiedChinese,
                "打开 MoneyUp 以继续记账",
                "需要解锁",
                "无需解锁"
            )
        ]

        for expectation in expectations {
            languageDefaults.set(
                expectation.language.rawValue,
                forKey: AppLanguagePreference.storageKey
            )
            let capture = AppLocalization.string(
                "platform_action.capture_without_unlock"
            )
            XCTAssertEqual(capture, expectation.capture)
            XCTAssertFalse(capture.contains(expectation.forbidden))
            XCTAssertEqual(
                AppLocalization.string("platform_action.unlock_required"),
                expectation.unlock
            )
        }
    }

    func testAllowanceMutationAndPolicyZoneCopyIsBilingual() {
        XCTAssertEqual(
            AppLocalization.string(
                "allowance.prepaid_spendable_at_transaction_time",
                language: .english
            ),
            "Spendable at transaction time"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "allowance.prepaid_spendable_at_transaction_time",
                language: .simplifiedChinese
            ),
            "交易时点可用余额"
        )
        for key in [
            "allowance.usage.updating",
            "allowance.usage.delete_title",
            "allowance.usage.delete_detail",
            "allowance.usage.edit",
            "allowance.policy_time_zone",
            "allowance.policy_time_zone_detail",
            "allowance.date_unavailable",
            "allowance.legacy_partial_day_detail",
            "allowance.legacy_exact_start",
            "allowance.legacy_exact_end",
            "allowance.usage.deleted_title",
            "allowance.usage.deleted_detail",
            "account.restricted_funding_history",
            "account.restricted_funding_empty",
            "account.restricted_funding_history_detail",
            "account.restricted_funding_correct",
            "account.restricted_funding_original",
            "account.restricted_funding_corrected",
            "account.restricted_funding_correction_detail"
        ] {
            XCTAssertNotEqual(
                AppLocalization.string(key, language: .english),
                key
            )
            XCTAssertNotEqual(
                AppLocalization.string(key, language: .simplifiedChinese),
                key
            )
        }
        let reimbursementEnglish = AppLocalization.string(
            "allowance.legacy_reimbursement_detail",
            language: .english
        )
        let reimbursementChinese = AppLocalization.string(
            "allowance.legacy_reimbursement_detail",
            language: .simplifiedChinese
        )
        XCTAssertTrue(reimbursementEnglish.contains("Every claim status"))
        XCTAssertTrue(reimbursementEnglish.contains("record the actual reimbursement"))
        XCTAssertFalse(reimbursementEnglish.contains("until approved"))
        XCTAssertTrue(reimbursementChinese.contains("所有申请状态"))
        XCTAssertTrue(reimbursementChinese.contains("另行记录实际报销款"))
    }
}
