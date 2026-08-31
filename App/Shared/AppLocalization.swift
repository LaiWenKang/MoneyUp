import Foundation
import SwiftUI

private final class AppLocalizationBundleToken {}

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
    static func string(_ key: String) -> String {
        let owner = Bundle(for: AppLocalizationBundleToken.self)
        guard AppLanguagePreference.current != .system,
              let localizedBundle = localizedBundle(
                  for: AppLanguagePreference.current,
                  owner: owner
              ) else {
            return owner.localizedString(forKey: key, value: key, table: nil)
        }
        return localizedBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    private static func localizedBundle(
        for language: AppLanguagePreference,
        owner: Bundle
    ) -> Bundle? {
        let candidates = [owner, Bundle.main]
            + Bundle.allBundles
            + Bundle.allFrameworks
        for candidate in candidates {
            guard let url = candidate.url(
                forResource: language.rawValue,
                withExtension: "lproj"
            ), let bundle = Bundle(url: url) else { continue }
            return bundle
        }
        return nil
    }
}
