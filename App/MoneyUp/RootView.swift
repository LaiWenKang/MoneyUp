import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.state {
        case .launching:
            LaunchingView()
        case .locked:
            if model.canPresentLockedQuickCapture,
               let mode = model.requestedQuickLogMode {
                LockedQuickCaptureView(mode: mode)
            } else {
                LockedView()
            }
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
            MoneyUpBrandMark()
                .frame(width: 72, height: 72)
            ProgressView()
            Text("lock.opening")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { MoneyUpBackdrop() }
    }
}

private struct LockedView: View {
    @EnvironmentObject private var model: AppModel
    private let method = UnlockMethod.current

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: method.systemImage)
                .font(.system(size: 52))
                .foregroundStyle(method.isAvailable ? Color.accentColor : Color.orange)
                .accessibilityHidden(true)
            Text("lock.title")
                .font(.largeTitle.bold())

            if method.isAvailable {
                Text("lock.detail")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.start() }
                } label: {
                    Label(method.unlockTitle, systemImage: method.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking)
            } else {
                // The database key is stored WhenPasscodeSetThisDeviceOnly, so
                // without a device passcode there is nothing to unlock with.
                Text("lock.no_passcode")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background { MoneyUpBackdrop() }
    }
}

private struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel
    let message: String
    @State private var isConfirmingReset = false
    @State private var isShowingDataSafety = false

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

            Button {
                isShowingDataSafety = true
            } label: {
                Label("recovery.backup_or_restore", systemImage: "externaldrive.badge.shield.checkmark")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)

            Button("recovery.erase", role: .destructive) {
                isConfirmingReset = true
            }
            .disabled(model.isWorking)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { MoneyUpBackdrop() }
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
        .sheet(isPresented: $isShowingDataSafety) {
            NavigationStack {
                DataSafetyView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("action.close") { isShowingDataSafety = false }
                        }
                    }
            }
            .environmentObject(model)
        }
    }
}

private enum MoneyUpSection: Hashable {
    case today
    case history
    case log
    case plan
    case assets
}

private struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSection: MoneyUpSection = .today
    @State private var quickLogKind: QuickLogKind = .expense
    @State private var quickLogLaunchMode: QuickLogLaunchMode?
    @State private var logRequestSequence = 0
    @State private var isShowingWhatsNew = false
    @State private var hasCheckedForUpdate = false

    var body: some View {
        TabView(selection: $selectedSection) {
            DashboardView(
                onOpenLog: { selectedSection = .log },
                onOpenPlan: { selectedSection = .plan }
            )
                .tabItem { Label("tab.today", systemImage: "house.fill") }
                .tag(MoneyUpSection.today)

            HistoryView()
                .tabItem { Label("tab.history", systemImage: "clock.arrow.circlepath") }
                .tag(MoneyUpSection.history)

            LogView(
                kind: $quickLogKind,
                isActive: selectedSection == .log,
                launchMode: quickLogLaunchMode,
                requestSequence: logRequestSequence,
                onRequestHandled: { mode in
                    model.consumeQuickLogRequest(mode)
                },
                onNavigate: { destination in
                    switch destination {
                    case .today:
                        selectedSection = .today
                    case .history:
                        selectedSection = .history
                    case .plan:
                        selectedSection = .plan
                    case .assets:
                        selectedSection = .assets
                    }
                }
            )
                .tabItem { Label("tab.log", systemImage: "plus.circle.fill") }
                .tag(MoneyUpSection.log)

            PlanView()
                .tabItem { Label("tab.plan", systemImage: "chart.pie.fill") }
                .tag(MoneyUpSection.plan)

            AssetsView()
                .tabItem { Label("tab.assets", systemImage: "wallet.bifold.fill") }
                .tag(MoneyUpSection.assets)
        }
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewSheet()
        }
        .onAppear {
            checkForUpdate(suppressPresentation: openRequestedLog())
        }
        .onChange(of: model.requestedQuickLogMode) { _, _ in
            openRequestedLog()
        }
    }

    /// Private TestFlight and source installs show these notes once per version.
    private func checkForUpdate(suppressPresentation: Bool) {
        guard !suppressPresentation else { return }
        guard !hasCheckedForUpdate else { return }
        hasCheckedForUpdate = true
        guard AppVersion.consumeUpdateFlag(), !ReleaseNotes.highlights().isEmpty else {
            return
        }
        isShowingWhatsNew = true
    }

    /// Widget, Shortcut, and URL requests route into the permanent Log tab
    /// instead of creating a modal on top of whichever screen was open.
    @discardableResult
    private func openRequestedLog() -> Bool {
        guard let requestedMode = model.requestedQuickLogMode else { return false }
        isShowingWhatsNew = false
        quickLogLaunchMode = requestedMode
        logRequestSequence &+= 1
        selectedSection = .log
        return true
    }
}
