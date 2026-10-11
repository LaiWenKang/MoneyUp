import SwiftUI
import UIKit

enum MoneyUpTypography {
    enum FinancialValueStyle: CaseIterable, Equatable, Sendable {
        case hero
        case prominent
        case standard
        case compact
    }

    enum TextRole: Equatable, Sendable {
        case largeTitle
        case title2
        case body
        case subheadline
    }

    enum Weight: Equatable, Sendable {
        case medium
        case semibold
        case bold
    }

    struct FinancialValuePolicy: Equatable, Sendable {
        let textRole: TextRole
        let weight: Weight
        let usesRoundedDesign: Bool
        let usesMonospacedDigits: Bool
        /// A display size scaled with Dynamic Type relative to `textRole`;
        /// nil uses the text style's own size.
        var displayPointSize: CGFloat? = nil
    }

    /// The headline figure: a third larger than Large Title so one number per
    /// screen leads, and it shrinks before it would ever wrap.
    static let heroPointSize: CGFloat = 44
    static let heroMinimumScaleFactor: CGFloat = 0.5

    static func financialValuePolicy(
        for style: FinancialValueStyle
    ) -> FinancialValuePolicy {
        switch style {
        case .hero:
            FinancialValuePolicy(
                textRole: .largeTitle,
                weight: .bold,
                usesRoundedDesign: true,
                usesMonospacedDigits: true,
                displayPointSize: heroPointSize
            )
        case .prominent:
            FinancialValuePolicy(
                textRole: .title2,
                weight: .semibold,
                usesRoundedDesign: true,
                usesMonospacedDigits: true
            )
        case .standard:
            FinancialValuePolicy(
                textRole: .body,
                weight: .semibold,
                usesRoundedDesign: false,
                usesMonospacedDigits: true
            )
        case .compact:
            FinancialValuePolicy(
                textRole: .subheadline,
                weight: .semibold,
                usesRoundedDesign: false,
                usesMonospacedDigits: true
            )
        }
    }

    /// The font for a financial value. A display size is scaled for the
    /// current content size; views pass their own `@ScaledMetric` size so an
    /// environment Dynamic Type override is honoured too.
    static func financialValueFont(
        for style: FinancialValueStyle,
        scaledPointSize: CGFloat? = nil
    ) -> Font {
        let policy = financialValuePolicy(for: style)
        let design: Font.Design = policy.usesRoundedDesign ? .rounded : .default
        let weight = swiftUIWeight(for: policy.weight)
        if let base = policy.displayPointSize {
            let size = scaledPointSize
                ?? UIFontMetrics(forTextStyle: uiTextStyle(for: policy.textRole)).scaledValue(for: base)
            return .system(size: size, weight: weight, design: design)
        }
        return .system(swiftUITextStyle(for: policy.textRole), design: design, weight: weight)
    }

    private static func uiTextStyle(for role: TextRole) -> UIFont.TextStyle {
        switch role {
        case .largeTitle: .largeTitle
        case .title2: .title2
        case .body: .body
        case .subheadline: .subheadline
        }
    }

    private static func swiftUITextStyle(for role: TextRole) -> Font.TextStyle {
        switch role {
        case .largeTitle: .largeTitle
        case .title2: .title2
        case .body: .body
        case .subheadline: .subheadline
        }
    }

    private static func swiftUIWeight(for weight: Weight) -> Font.Weight {
        switch weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

private struct MoneyUpFinancialValueModifier: ViewModifier {
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = MoneyUpTypography.heroPointSize
    let style: MoneyUpTypography.FinancialValueStyle

    func body(content: Content) -> some View {
        let policy = MoneyUpTypography.financialValuePolicy(for: style)
        let motion = MoneyUpMotion.policy(
            for: .financialValue,
            reduceMotion: reduceMotion
        )
        let isDisplay = policy.displayPointSize != nil
        content
            .font(MoneyUpTypography.financialValueFont(for: style, scaledPointSize: isDisplay ? heroSize : nil))
            // A headline amount stays on one line and shrinks instead of
            // breaking a number in two.
            .lineLimit(isDisplay ? 1 : nil)
            .minimumScaleFactor(isDisplay ? MoneyUpTypography.heroMinimumScaleFactor : 1)
            .modifier(
                MoneyUpFinancialDigitModifier(
                    usesMonospacedDigits: policy.usesMonospacedDigits
                )
            )
            .transaction { transaction in
                if motion == .immediate { transaction.animation = nil }
            }
    }
}

private struct MoneyUpFinancialDigitModifier: ViewModifier {
    let usesMonospacedDigits: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesMonospacedDigits {
            content.monospacedDigit()
        } else {
            content
        }
    }
}

extension View {
    /// Applies MoneyUp's financial hierarchy without animating stale digits.
    func moneyUpFinancialValue(
        _ style: MoneyUpTypography.FinancialValueStyle = .standard
    ) -> some View {
        modifier(MoneyUpFinancialValueModifier(style: style))
    }
}
