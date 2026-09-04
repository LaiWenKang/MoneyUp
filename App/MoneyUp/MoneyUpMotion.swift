import SwiftUI

/// Semantic motion decisions for MoneyUp-owned content.
///
/// Native tab selection and sheet presentation deliberately remain native.
/// Financial values are always immediate so animation can never postpone the
/// amount a person is making a decision from.
enum MoneyUpMotion {
    enum Context: CaseIterable, Equatable, Sendable {
        case financialValue
        case confirmation
        case stateChange
        case selection
        case disclosure
        case press
        case tabNavigation
        case sheetPresentation
    }

    enum Policy: Equatable, Sendable {
        case immediate
        case native
        case snappy(duration: Double)
        case easeInOut(duration: Double)
        case spring(
            response: Double,
            dampingFraction: Double,
            blendDuration: Double
        )
    }

    static func policy(
        for context: Context,
        reduceMotion: Bool
    ) -> Policy {
        switch context {
        case .financialValue:
            .immediate
        case .confirmation:
            reduceMotion ? .immediate : .snappy(duration: 0.22)
        case .stateChange:
            reduceMotion ? .immediate : .easeInOut(duration: 0.20)
        case .selection:
            reduceMotion ? .immediate : .snappy(duration: 0.24)
        case .disclosure:
            reduceMotion
                ? .immediate
                : .spring(
                    response: 0.42,
                    dampingFraction: 0.88,
                    blendDuration: 0.08
                )
        case .press:
            reduceMotion ? .immediate : .snappy(duration: 0.14)
        case .tabNavigation, .sheetPresentation:
            .native
        }
    }

    static func animation(
        for context: Context,
        reduceMotion: Bool
    ) -> Animation? {
        switch policy(for: context, reduceMotion: reduceMotion) {
        case .immediate, .native:
            nil
        case let .snappy(duration):
            .snappy(duration: duration)
        case let .easeInOut(duration):
            .easeInOut(duration: duration)
        case let .spring(response, dampingFraction, blendDuration):
            .spring(
                response: response,
                dampingFraction: dampingFraction,
                blendDuration: blendDuration
            )
        }
    }

    static func confirmationTransition(
        reduceMotion: Bool
    ) -> AnyTransition {
        switch policy(for: .confirmation, reduceMotion: reduceMotion) {
        case .immediate, .native:
            .identity
        case .snappy, .easeInOut, .spring:
            .move(edge: .bottom).combined(with: .opacity)
        }
    }

    static func disclosureTransition(
        reduceMotion: Bool
    ) -> AnyTransition {
        guard policy(for: .disclosure, reduceMotion: reduceMotion) != .immediate else {
            return .identity
        }
        return .asymmetric(
            insertion: .opacity.combined(
                with: .scale(scale: 0.985, anchor: .top)
            ),
            removal: .opacity
        )
    }
}

/// A restrained press response for custom card and capsule controls. Native
/// buttons keep their own system feedback; this style is only for controls
/// whose `.plain` style would otherwise feel inert.
struct MoneyUpPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.985 : 1
            )
            .opacity(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .animation(
                MoneyUpMotion.animation(
                    for: .press,
                    reduceMotion: reduceMotion
                ),
                value: configuration.isPressed
            )
    }
}
