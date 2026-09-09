import MoneyUpCore
import SwiftUI
import UIKit

enum MoneyAmountKeyboardLayout: Equatable {
    case numberOnly
    case decimal
    case signed
}

func moneyAmountKeyboardLayout(
    currency: CurrencyCode?,
    allowsNegative: Bool = false
) -> MoneyAmountKeyboardLayout {
    if allowsNegative { return .signed }
    return currency?.minorUnits == 0 ? .numberOnly : .decimal
}

private extension MoneyAmountKeyboardLayout {
    var keyboardType: UIKeyboardType {
        switch self {
        case .numberOnly: .numberPad
        case .decimal: .decimalPad
        case .signed: .numbersAndPunctuation
        }
    }
}

extension View {
    /// Selects a currency-aware keypad without changing parsing or validation.
    /// Signed asset balances keep a keyboard that can enter a minus sign.
    func moneyAmountKeyboard(
        currency: CurrencyCode?,
        allowsNegative: Bool = false
    ) -> some View {
        keyboardType(
            moneyAmountKeyboardLayout(
                currency: currency,
                allowsNegative: allowsNegative
            ).keyboardType
        )
    }
}

/// Decimal and number pads have no Return key. Screens that do not own a more
/// specific FocusState toolbar use this shared escape so the keyboard can
/// never cover the final action or trap Switch Control/Voice Control users.
struct MoneyUpKeyboardDoneToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("action.done") {
                MoneyUpKeyboard.dismiss()
            }
        }
    }
}

@MainActor
enum MoneyUpKeyboard {
    static var hasMarkedText: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).contains { hasMarkedText(in: $0) }
    }

    static func hasMarkedText(in view: UIView) -> Bool {
        if view.isFirstResponder, let input = view as? any UITextInput {
            return input.markedTextRange != nil
        }
        return view.subviews.contains { hasMarkedText(in: $0) }
    }

    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}
