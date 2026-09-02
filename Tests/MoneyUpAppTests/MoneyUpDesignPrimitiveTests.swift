@testable import MoneyUp
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
