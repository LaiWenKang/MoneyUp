import Foundation
import SwiftUI

/// A non-sensitive UI preference shared by the app and widget. Financial
/// parsing and persisted reporting zones remain owned by domain settings.
enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    static let storageKey = "moneyup.app-language"

    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            .autoupdatingCurrent
        case .english:
            Locale(identifier: "en")
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "settings.language.system"
        case .english: "settings.language.english"
        case .simplifiedChinese: "settings.language.simplified_chinese"
        }
    }

    static var defaults: UserDefaults {
        UserDefaults(
            suiteName: BudgetWidgetSnapshotStore.appGroupIdentifier
        ) ?? .standard
    }

    static var current: AppLanguagePreference {
        let stored = defaults.string(forKey: storageKey)
        return stored.flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
    }
}

/// Programmatic strings do not inherit SwiftUI's locale environment. Route
/// those lookups through the same persisted preference so formatted labels and
/// accessibility messages switch with the visible interface.
enum AppLocalization {
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, locale: AppLanguagePreference.current.locale)
    }
}
