import SwiftUI

private struct MoneyUpAdditionalMotionReductionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MoneyUpIllustrationsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var moneyUpReduceMotion: Bool {
        get { accessibilityReduceMotion || self[MoneyUpAdditionalMotionReductionKey.self] }
        set { self[MoneyUpAdditionalMotionReductionKey.self] = newValue }
    }

    var moneyUpShowsIllustrations: Bool {
        get { self[MoneyUpIllustrationsKey.self] }
        set { self[MoneyUpIllustrationsKey.self] = newValue }
    }
}
