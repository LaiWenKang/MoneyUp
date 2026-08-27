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
/// Private TestFlight and source builds cannot rely on a public App Store page
/// to explain an update. These in-app notes keep both paths understandable.
enum ReleaseNotes {
    static func highlights(for version: String = AppVersion.marketing) -> [LocalizedStringKey] {
        switch version {
        case "0.6.0":
            [
                "whats_new.0_6_0.history",
                "whats_new.0_6_0.investments",
                "whats_new.0_6_0.plan",
                "whats_new.0_6_0.portability",
                "whats_new.0_6_0.widget"
            ]
        case "0.5.2":
            [
                "whats_new.0_5_2.keyboard",
                "whats_new.0_5_2.receipt",
                "whats_new.0_5_2.verification"
            ]
        case "0.5.1":
            [
                "whats_new.0_5_1.flexible",
                "whats_new.0_5_1.capture",
                "whats_new.0_5_1.focus",
                "whats_new.0_5_1.visuals"
            ]
        case "0.5.0":
            [
                "whats_new.0_5_0.guidance",
                "whats_new.0_5_0.simulator",
                "whats_new.0_5_0.insights",
                "whats_new.0_5_0.visuals"
            ]
        case "0.4.1":
            [
                "whats_new.0_4_1.guidance",
                "whats_new.0_4_1.history",
                "whats_new.0_4_1.safety",
                "whats_new.0_4_1.import"
            ]
        case "0.4.0":
            [
                "whats_new.0_4_0.log",
                "whats_new.0_4_0.widgets",
                "whats_new.0_4_0.trust"
            ]
        case "0.3.0":
            [
                "whats_new.0_3_0.privacy",
                "whats_new.0_3_0.deletion",
                "whats_new.0_3_0.beta"
            ]
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
            .background { MoneyUpBackdrop() }
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
