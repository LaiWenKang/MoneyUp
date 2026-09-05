import SwiftUI

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
    }

    static func financialValuePolicy(
        for style: FinancialValueStyle
    ) -> FinancialValuePolicy {
        switch style {
        case .hero:
            FinancialValuePolicy(
                textRole: .largeTitle,
                weight: .bold,
                usesRoundedDesign: true,
                usesMonospacedDigits: true
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

    static func financialValueFont(
        for style: FinancialValueStyle
    ) -> Font {
        let policy = financialValuePolicy(for: style)
        return .system(
            swiftUITextStyle(for: policy.textRole),
            design: policy.usesRoundedDesign ? .rounded : .default,
            weight: swiftUIWeight(for: policy.weight)
        )
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
    let style: MoneyUpTypography.FinancialValueStyle

    func body(content: Content) -> some View {
        let policy = MoneyUpTypography.financialValuePolicy(for: style)
        let motion = MoneyUpMotion.policy(
            for: .financialValue,
            reduceMotion: reduceMotion
        )
        content
            .font(MoneyUpTypography.financialValueFont(for: style))
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
