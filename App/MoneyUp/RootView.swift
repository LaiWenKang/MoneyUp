import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.state {
        case .launching:
            LaunchingView()
        case .locked:
            LockedView()
        case .onboarding:
            OnboardingView()
        case .ready:
            MainTabView()
        case let .failed(message):
            RecoveryView(message: message)
        }
    }
}

private struct LaunchingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            ProgressView()
            Text("lock.opening")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct LockedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("lock.title")
                .font(.largeTitle.bold())
            Text("lock.detail")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.start() }
            } label: {
                Label("lock.unlock", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isWorking)
        }
        .padding(32)
        .frame(maxWidth: 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel
    let message: String
    @State private var isConfirmingReset = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("error.could_not_open")
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("action.try_again") {
                Task { await model.start() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)

            Button("recovery.erase", role: .destructive) {
                isConfirmingReset = true
            }
            .disabled(model.isWorking)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .confirmationDialog(
            "recovery.erase_title",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("recovery.erase_confirm", role: .destructive) {
                Task { await model.eraseAllDataAndRestart() }
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("recovery.erase_detail")
        }
    }
}

private enum MoneyUpSection: Hashable {
    case today
    case plan
    case calendar
    case insights
    case assets
}

private struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSection: MoneyUpSection = .today
    @State private var isPresentingQuickLog = false
    @State private var quickLogKind: QuickLogKind = .expense

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedSection) {
                DashboardView()
                    .tabItem { Label("tab.today", systemImage: "house.fill") }
                    .tag(MoneyUpSection.today)

                PlanView()
                    .tabItem { Label("tab.plan", systemImage: "target") }
                    .tag(MoneyUpSection.plan)

                CalendarView()
                    .tabItem { Label("tab.calendar", systemImage: "calendar") }
                    .tag(MoneyUpSection.calendar)

                InsightsView()
                    .tabItem { Label("tab.insights", systemImage: "chart.bar.fill") }
                    .tag(MoneyUpSection.insights)

                AssetsView()
                    .tabItem { Label("tab.assets", systemImage: "creditcard.fill") }
                    .tag(MoneyUpSection.assets)
            }

            Button {
                quickLogKind = .expense
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
            QuickLogSheet(initialKind: quickLogKind)
        }
        .onAppear { presentRequestedQuickLog() }
        .onChange(of: model.requestedQuickLogKind) { _, _ in
            presentRequestedQuickLog()
        }
    }

    private func presentRequestedQuickLog() {
        guard let requestedKind = model.requestedQuickLogKind else { return }
        quickLogKind = requestedKind
        isPresentingQuickLog = true
        model.consumeQuickLogRequest()
    }
}
