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
