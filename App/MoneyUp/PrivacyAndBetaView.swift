import Foundation
import SwiftUI

struct PrivacyAndBetaView: View {
    private static let privacyPolicyURL = URL(
        string: "https://github.com/LaiWenKang/MoneyUp/blob/main/PRIVACY.md"
    )
    private static let supportURL = URL(
        string: "https://github.com/LaiWenKang/MoneyUp/blob/main/SUPPORT.md"
    )

    var body: some View {
        List {
            Section {
                PrivacyRow(
                    icon: "iphone.gen3",
                    title: "privacy.local_title",
                    detail: "privacy.local_detail"
                )
                PrivacyRow(
                    icon: "lock.shield.fill",
                    title: "privacy.protected_title",
                    detail: "privacy.protected_detail"
                )
                PrivacyRow(
                    icon: "eye.slash.fill",
                    title: "privacy.no_tracking_title",
                    detail: "privacy.no_tracking_detail"
                )
            } header: {
                Text("privacy.summary")
            }

            Section {
                PrivacyRow(
                    icon: "square.and.arrow.up",
                    title: "privacy.export_title",
                    detail: "privacy.export_detail"
                )
                PrivacyRow(
                    icon: "externaldrive.badge.exclamationmark",
                    title: "privacy.recovery_title",
                    detail: "privacy.recovery_detail"
                )
            } header: {
                Text("privacy.your_choices")
            }

            Section {
                PrivacyRow(
                    icon: "testtube.2",
                    title: "testing.first_title",
                    detail: "testing.first_detail"
                )
                PrivacyRow(
                    icon: "exclamationmark.bubble.fill",
                    title: "testing.feedback_title",
                    detail: "testing.feedback_detail"
                )

                LabeledContent("assets.version", value: AppVersion.display)
            } header: {
                Text("testing.title")
            }

            if let url = Self.privacyPolicyURL {
                Section {
                    Link(destination: url) {
                        Label("privacy.read_policy", systemImage: "safari")
                    }

                    if let supportURL = Self.supportURL {
                        Link(destination: supportURL) {
                            Label("testing.read_support", systemImage: "questionmark.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("privacy.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }
}
