import Foundation
import SwiftUI

/// The running build's identity, read from the bundle so it always reflects
/// what was actually installed.
enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var display: String { "\(marketing) (\(build))" }

    private static let lastSeenKey = "moneyup.lastSeenVersion"

    /// True the first time a new version runs after an older one, and false on
    /// a fresh install, where there is nothing yet to announce. Records the
    /// current version as it answers, so it is true only once per update.
    ///
    /// Only a version string is stored. Nothing financial goes in `UserDefaults`.
    static func consumeUpdateFlag(defaults: UserDefaults = .standard) -> Bool {
        let current = marketing
        let previous = defaults.string(forKey: lastSeenKey)
        defaults.set(current, forKey: lastSeenKey)
        return previous != nil && previous != current
    }
}

/// What changed in the running version.
///
/// MoneyUp is installed from source, so there is no App Store release note to
/// read. This is the only place an update announces itself, which is why it
/// lives beside the version rather than in a changelog the app cannot show.
enum ReleaseNotes {
    static func highlights(for version: String = AppVersion.marketing) -> [LocalizedStringKey] {
        switch version {
        case "0.2.0":
            [
                "whats_new.0_2_0.currencies",
                "whats_new.0_2_0.periods",
                "whats_new.0_2_0.smart_entry",
                "whats_new.0_2_0.appearance"
            ]
        default:
            []
        }
    }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let highlights = ReleaseNotes.highlights()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("whats_new.subtitle \(AppVersion.marketing)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(Array(highlights.enumerated()), id: \.offset) { entry in
                        Label {
                            Text(entry.element)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("whats_new.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.continue") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
