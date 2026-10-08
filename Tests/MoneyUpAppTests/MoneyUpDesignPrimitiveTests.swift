@testable import MoneyUp
import Foundation
import SwiftUI
import UIKit
import XCTest

final class MoneyUpDesignPrimitiveTests: XCTestCase {
    func testFinancialValuesAreMonospacedAndImmediateAtEveryScale() {
        for style in MoneyUpTypography.FinancialValueStyle.allCases {
            let typography = MoneyUpTypography.financialValuePolicy(for: style)
            XCTAssertTrue(typography.usesMonospacedDigits)
            XCTAssertEqual(
                MoneyUpMotion.policy(
                    for: .financialValue,
                    reduceMotion: false
                ),
                .immediate
            )
            XCTAssertEqual(
                MoneyUpMotion.policy(
                    for: .financialValue,
                    reduceMotion: true
                ),
                .immediate
            )
        }
    }

    /// One headline figure per screen: only the hero has a display size, and
    /// it is larger than the Large Title the rest of the scale tops out at.
    func testOnlyTheHeroAmountUsesTheDisplaySize() {
        for style in MoneyUpTypography.FinancialValueStyle.allCases {
            let size = MoneyUpTypography.financialValuePolicy(for: style).displayPointSize
            XCTAssertEqual(size != nil, style == .hero, "\(style)")
        }
        let largeTitle = UIFont.preferredFont(
            forTextStyle: .largeTitle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        XCTAssertGreaterThan(MoneyUpTypography.heroPointSize, largeTitle)
        XCTAssertLessThan(MoneyUpTypography.heroMinimumScaleFactor, 1)
    }

    /// The currency code or symbol steps down; digits, separators, signs and
    /// the privacy mask keep the headline size, in any locale's order.
    func testHeroAmountsStepDownOnlyTheCurrencyMarks() {
        func marks(_ text: String) -> [String] {
            MoneyUpHeroAmountRuns.split(text).filter(\.isCurrencyMark).map(\.text)
        }
        func figures(_ text: String) -> String {
            MoneyUpHeroAmountRuns.split(text).filter { !$0.isCurrencyMark }.map(\.text).joined()
        }
        XCTAssertEqual(marks("SGD 1,730.30"), ["SGD"])
        XCTAssertEqual(figures("SGD 1,730.30"), " 1,730.30")
        XCTAssertEqual(marks("$1,250.00"), ["$"])
        XCTAssertEqual(marks("1.730,30 €"), ["€"])
        XCTAssertEqual(figures("1.730,30 €"), "1.730,30 ")
        XCTAssertEqual(marks("-SGD 5.00"), ["SGD"])
        XCTAssertEqual(figures("-SGD 5.00"), "- 5.00")
        XCTAssertEqual(marks(MoneyAmountPrivacy.placeholder), [])
        for text in ["SGD 1,730.30", "≈ SGD 9,951.50", "¥12,000", MoneyAmountPrivacy.placeholder] {
            XCTAssertEqual(MoneyUpHeroAmountRuns.split(text).map(\.text).joined(), text)
        }
    }

    /// Goals carry identity colour only; warning and danger stay reserved.
    func testGoalIdentityColoursNeverUseStatusColours() {
        XCTAssertFalse(MoneyUpChartPalette.identity.contains(.moneyUpWarning))
        XCTAssertFalse(MoneyUpChartPalette.identity.contains(.moneyUpDanger))
        for _ in 0..<64 {
            let id = UUID()
            let colour = MoneyUpChartPalette.identityColor(for: id)
            XCTAssertEqual(colour, MoneyUpChartPalette.identityColor(for: id))
            XCTAssertTrue(MoneyUpChartPalette.identity.contains(colour))
        }
    }

    /// A press reads through scale; a deep fade would look disabled.
    func testPressFeedbackLeadsWithScaleNotFade() {
        XCTAssertLessThan(MoneyUpPressableButtonStyle.pressedScale, 0.985)
        XCTAssertGreaterThan(MoneyUpPressableButtonStyle.pressedScale, 0.95)
        XCTAssertGreaterThan(MoneyUpPressableButtonStyle.pressedOpacity, 0.9)
    }

    func testReduceMotionRemovesMoneyUpOwnedMotion() {
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .confirmation, reduceMotion: false),
            .snappy(duration: 0.22)
        )
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .confirmation, reduceMotion: true),
            .immediate
        )
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .stateChange, reduceMotion: false),
            .easeInOut(duration: 0.20)
        )
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .stateChange, reduceMotion: true),
            .immediate
        )
    }

    func testPremiumInteractionMotionFallsBackToImmediateUpdates() {
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .selection, reduceMotion: false),
            .snappy(duration: 0.24)
        )
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .disclosure, reduceMotion: false),
            .spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.08)
        )
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .press, reduceMotion: false),
            .snappy(duration: 0.14)
        )

        for context in [
            MoneyUpMotion.Context.selection,
            .disclosure,
            .press,
        ] {
            XCTAssertEqual(
                MoneyUpMotion.policy(for: context, reduceMotion: true),
                .immediate
            )
        }
    }

    func testAmountPrivacyFailsPrivateUntilExplicitlyChanged() throws {
        let suiteName = "MoneyUpTests.AmountPrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MoneyAmountPrivacy.hidesAmounts(in: defaults))
        XCTAssertEqual(
            MoneyAmountPrivacy.protected("SGD 1,034.10", hidesAmounts: true),
            "*****"
        )
        XCTAssertEqual(
            MoneyAmountPrivacy.protected("SGD 1,034.10", hidesAmounts: false),
            "SGD 1,034.10"
        )

        defaults.set(false, forKey: MoneyAmountPrivacy.storageKey)
        XCTAssertFalse(MoneyAmountPrivacy.hidesAmounts(in: defaults))
    }

    func testTabAndSheetTransitionsRemainNative() {
        for context in [
            MoneyUpMotion.Context.tabNavigation,
            .sheetPresentation
        ] {
            XCTAssertEqual(
                MoneyUpMotion.policy(for: context, reduceMotion: false),
                .native
            )
            XCTAssertEqual(
                MoneyUpMotion.policy(for: context, reduceMotion: true),
                .native
            )
        }
    }

    func testFeedbackHapticsAreLimitedToConsequentialResults() {
        let consequentialEvents: [
            (MoneyUpFeedback.Event, MoneyUpFeedback.Haptic)
        ] = [
            (.financialCommit, .success),
            (.destructiveCommit, .warning),
            (.validationFailure, .error),
        ]
        for (event, haptic) in consequentialEvents {
            XCTAssertEqual(
                MoneyUpFeedback.policy(for: event),
                .init(haptic: haptic, requiresVisibleStatus: true)
            )
            XCTAssertEqual(
                MoneyUpFeedback.haptic(for: event, visibleStatus: false),
                .none
            )
            XCTAssertEqual(
                MoneyUpFeedback.haptic(for: event, visibleStatus: true),
                haptic
            )
        }
        for event in [
            MoneyUpFeedback.Event.selection,
            .navigation,
            .presentation
        ] {
            XCTAssertEqual(
                MoneyUpFeedback.policy(for: event),
                .init(haptic: .none, requiresVisibleStatus: false)
            )
        }
    }

    func testFeedbackRequiresATriggerTransitionAndSimultaneousVisibleStatus() {
        XCTAssertEqual(
            MoneyUpFeedback.haptic(
                for: .financialCommit,
                previousTrigger: 1,
                currentTrigger: 1,
                visibleStatus: true
            ),
            .none
        )
        XCTAssertEqual(
            MoneyUpFeedback.haptic(
                for: .financialCommit,
                previousTrigger: 1,
                currentTrigger: 2,
                visibleStatus: false
            ),
            .none
        )
        XCTAssertEqual(
            MoneyUpFeedback.haptic(
                for: .financialCommit,
                previousTrigger: 1,
                currentTrigger: 2,
                visibleStatus: true
            ),
            .success
        )
    }

    func testRaisedCardPreservesTheLegacyDefaultAppearance() {
        XCTAssertEqual(MoneyUpCardPolicy.defaultStyle, .raised)
        XCTAssertEqual(
            MoneyUpCardPolicy.appearance(
                for: .raised,
                reduceTransparency: false,
                increaseContrast: false
            ),
            MoneyUpCardAppearance(
                surface: .elevated,
                borderStyle: .gradient,
                accentBorderOpacity: 0.18,
                primaryBorderOpacity: 0.055,
                borderWidth: 1,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowOffsetY: 0
            )
        )
    }

    func testCardElevationStylesRemainOpaqueAndSemantic() {
        let flat = standardAppearance(for: .flat)
        let raised = standardAppearance(for: .raised)
        let floating = standardAppearance(for: .floating)

        XCTAssertEqual(flat.surface, .surface)
        XCTAssertEqual(raised.surface, .elevated)
        XCTAssertEqual(floating.surface, .elevated)
        XCTAssertEqual(flat.shadowOpacity, 0)
        XCTAssertEqual(raised.shadowOpacity, 0)
        XCTAssertGreaterThan(floating.shadowOpacity, 0)
        XCTAssertEqual(flat.borderStyle, .gradient)
        XCTAssertEqual(raised.borderStyle, .gradient)
        XCTAssertEqual(floating.borderStyle, .gradient)
    }

    func testCardAccessibilityPoliciesReduceEffectsAndIncreaseSeparation() {
        for style in MoneyUpCardStyle.allCases {
            let standard = standardAppearance(for: style)
            let reduced = MoneyUpCardPolicy.appearance(
                for: style,
                reduceTransparency: true,
                increaseContrast: false
            )
            let contrasted = MoneyUpCardPolicy.appearance(
                for: style,
                reduceTransparency: false,
                increaseContrast: true
            )
            let combined = MoneyUpCardPolicy.appearance(
                for: style,
                reduceTransparency: true,
                increaseContrast: true
            )

            XCTAssertEqual(reduced.borderStyle, .solid)
            XCTAssertEqual(reduced.accentBorderOpacity, 0)
            XCTAssertEqual(reduced.shadowOpacity, 0)
            XCTAssertEqual(contrasted.borderStyle, .gradient)
            XCTAssertGreaterThan(contrasted.borderWidth, standard.borderWidth)
            XCTAssertGreaterThan(
                contrasted.primaryBorderOpacity,
                standard.primaryBorderOpacity
            )
            XCTAssertEqual(combined.borderWidth, 2)
            XCTAssertEqual(combined.shadowOpacity, 0)
        }
    }

    private func standardAppearance(
        for style: MoneyUpCardStyle
    ) -> MoneyUpCardAppearance {
        MoneyUpCardPolicy.appearance(
            for: style,
            reduceTransparency: false,
            increaseContrast: false
        )
    }
}
