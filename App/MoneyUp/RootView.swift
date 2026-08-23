import SwiftUI

private enum MoneyUpSection: Hashable {
    case today
    case plan
    case calendar
    case insights
    case assets
}

struct RootView: View {
    @State private var selectedSection: MoneyUpSection = .today
    @State private var isPresentingQuickLog = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedSection) {
                DashboardView()
                    .tabItem {
                        Label("tab.today", systemImage: "house.fill")
                    }
                    .tag(MoneyUpSection.today)

                FeaturePlaceholderView(
                    titleKey: "tab.plan",
                    detailKey: "placeholder.plan",
                    systemImage: "list.bullet.indent"
                )
                .tabItem {
                    Label("tab.plan", systemImage: "target")
                }
                .tag(MoneyUpSection.plan)

                FeaturePlaceholderView(
                    titleKey: "tab.calendar",
                    detailKey: "placeholder.calendar",
                    systemImage: "calendar"
                )
                .tabItem {
                    Label("tab.calendar", systemImage: "calendar")
                }
                .tag(MoneyUpSection.calendar)

                FeaturePlaceholderView(
                    titleKey: "tab.insights",
                    detailKey: "placeholder.insights",
                    systemImage: "chart.xyaxis.line"
                )
                .tabItem {
                    Label("tab.insights", systemImage: "chart.bar.fill")
                }
                .tag(MoneyUpSection.insights)

                FeaturePlaceholderView(
                    titleKey: "tab.assets",
                    detailKey: "placeholder.assets",
                    systemImage: "building.columns"
                )
                .tabItem {
                    Label("tab.assets", systemImage: "creditcard.fill")
                }
                .tag(MoneyUpSection.assets)
            }

            Button {
                isPresentingQuickLog = true
            } label: {
                Label("action.quick_log", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .clipShape(Capsule())
            .padding(.trailing, 16)
            .padding(.bottom, 64)
            .accessibilityHint("action.quick_log.hint")
        }
        .sheet(isPresented: $isPresentingQuickLog) {
            QuickLogSheet()
        }
    }
}
