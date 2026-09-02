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
        case tabNavigation
        case sheetPresentation
    }

    enum Policy: Equatable, Sendable {
        case immediate
        case native
        case snappy(duration: Double)
        case easeInOut(duration: Double)
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
        }
    }

    static func confirmationTransition(
        reduceMotion: Bool
    ) -> AnyTransition {
        switch policy(for: .confirmation, reduceMotion: reduceMotion) {
        case .immediate, .native:
            .identity
        case .snappy, .easeInOut:
            .move(edge: .bottom).combined(with: .opacity)
        }
    }
}
