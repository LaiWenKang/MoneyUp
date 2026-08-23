import SwiftUI

struct DashboardView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                "dashboard.safe_to_spend",
                                systemImage: "checkmark.shield.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(.secondary)

                            Text("—")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))

                            Text("dashboard.awaiting_data")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dashboard.monthly_budget")
                                .font(.headline)
                            ProgressView(value: 0)
                            Text("dashboard.no_budget")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    DashboardCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("dashboard.private_by_design")
                                    .font(.headline)
                                Text("dashboard.privacy_detail")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("tab.today")
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .contain)
    }
}
