import MoneyUpCore
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.quickActionRouteBroker.isAuthoritativeBoundaryActive {
            LaunchingView()
                .id(model.quickActionRouteBroker.handoffGeneration)
        } else {
            switch model.state {
            case .launching:
                LaunchingView()
            case .locked:
                if model.canPresentLockedQuickCapture,
                   let request = model.requestedQuickLogRequest {
                    LockedQuickCaptureView(request: request)
                        .id(request.id)
                } else {
                    LockedView()
                }
            case .onboarding:
                OnboardingView()
            case .ready:
                MainTabView()
                    .id(model.quickActionRouteBroker.handoffGeneration)
            case let .failed(message):
                RecoveryView(message: message)
            }
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
    @Environment(AppModel.self) private var model
    private let method = UnlockMethod.current

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: method.systemImage)
                        .font(.system(size: 52))
                        .foregroundStyle(
                            method.isAvailable ? Color.accentColor : Color.orange
                        )
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
                        .tint(.moneyUpAction)
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
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background { MoneyUpBackdrop() }
    }
}

private struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    let message: String
    @State private var isConfirmingReset = false
    @State private var isShowingDataSafety = false

    private var recoveryActionKey: LocalizedStringKey {
        model.startupFailureKind == .missingDeviceBoundKey
            ? "recovery.key_cliff.restore_action"
            : "recovery.backup_or_restore"
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("error.could_not_open")
                        .font(.title2.bold())
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if model.startupFailureKind == .missingDeviceBoundKey {
                        Label(
                            "recovery.key_cliff.detail",
                            systemImage: "key.slash.fill"
                        )
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        Text("recovery.key_cliff.steps")
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                    }

                    Group {
                        if model.startupFailureKind == .missingDeviceBoundKey {
                            Button("recovery.key_cliff.retry") {
                                Task { await model.start() }
                            }
                        } else {
                            Button("action.try_again") {
                                Task { await model.start() }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.moneyUpAction)
                    .disabled(model.isWorking)

                    Button {
                        isShowingDataSafety = true
                    } label: {
                        Label(
                            recoveryActionKey,
                            systemImage: "externaldrive.badge.shield.checkmark"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)

                    Button("recovery.erase", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .disabled(model.isWorking)
                }
                .padding(32)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
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
            .environment(model)
        }
    }
}

enum MoneyUpSection: Hashable {
    case today
    case history
    case log
    case plan
    case assets
}

enum TabSwipeNavigationPolicy {
    static func destination(
        from current: MoneyUpSection,
        translation: CGSize
    ) -> MoneyUpSection? {
        guard abs(translation.width) >= 72,
              abs(translation.width) > abs(translation.height) * 1.6 else {
            return nil
        }
        let sections: [MoneyUpSection] = [.today, .history, .log, .plan, .assets]
        guard let index = sections.firstIndex(of: current) else { return nil }
        let target = translation.width < 0 ? index + 1 : index - 1
        guard sections.indices.contains(target) else { return nil }
        return sections[target]
    }
}

private struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSection: MoneyUpSection = .today
    @State private var quickLogKind: QuickLogKind = .expense
    @State private var historyReviewDate: Date?
    @State private var historyReviewSequence = 0
    @State private var isShowingWhatsNew = false
    @State private var hasCheckedForUpdate = false

    var body: some View {
        TabView(selection: $selectedSection) {
            DashboardView(
                initialReportingDate: model.currentDateForUserAction(),
                onOpenLog: { selectedSection = .log },
                onOpenPlan: { selectedSection = .plan }
            )
                .tabItem { Label("tab.today", systemImage: "house.fill") }
                .tag(MoneyUpSection.today)

            NavigationStack {
                HistoryView(preset: historyPreset(for: historyReviewDate))
            }
                .id(historyReviewSequence)
                .tabItem { Label("tab.history", systemImage: "clock.arrow.circlepath") }
                .tag(MoneyUpSection.history)

            LogView(
                kind: $quickLogKind,
                isActive: selectedSection == .log,
                launchRequest: model.presentedQuickLogRequest,
                onRequestHandled: { request in
                    model.consumeQuickLogRequest(request)
                },
                onNavigate: { destination in
                    switch destination {
                    case .today:
                        selectedSection = .today
                    case let .history(reviewDate):
                        if let reviewDate {
                            historyReviewDate = reviewDate
                            historyReviewSequence &+= 1
                        } else if historyReviewDate != nil {
                            historyReviewDate = nil
                            historyReviewSequence &+= 1
                        }
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { value in
                    guard model.profile?.enablesTabSwipeNavigation == true,
                          let destination = TabSwipeNavigationPolicy.destination(
                            from: selectedSection,
                            translation: value.translation
                          ) else { return }
                    withAnimation(.snappy) { selectedSection = destination }
                }
        )
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewSheet()
        }
        .onAppear {
            checkForUpdate(suppressPresentation: openRequestedLog())
            announcePendingRestoreCompletionAfterAppearance()
        }
        .onChange(of: model.requestedQuickLogRequest) { _, _ in
            openRequestedLog()
        }
        .onChange(of: model.pendingRestoreCompletionAnnouncement) { _, pending in
            guard pending != nil else { return }
            announcePendingRestoreCompletionAfterAppearance()
        }
    }

    private func announcePendingRestoreCompletionAfterAppearance() {
        Task { @MainActor in
            // Defer until the ready hierarchy has completed one render turn;
            // otherwise its own screen-change announcement can preempt this.
            await Task.yield()
            guard let completion = model
                .takeRestoreCompletionForReadyHierarchy() else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: completion
            )
        }
    }

    private func historyPreset(for reviewDate: Date?) -> HistoryPreset? {
        guard let reviewDate else { return nil }
        let calendar = model.reportingCalendar
        let start = FinancialPeriodBoundary.startOfDay(
            containing: reviewDate,
            calendar: calendar
        )
        guard let end = FinancialPeriodBoundary.endOfDayExclusive(
            containing: reviewDate,
            calendar: calendar
        ) else { return nil }
        return HistoryPreset(
            interval: DateInterval(
                start: start,
                end: end
            )
        )
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
        guard let request = model.requestedQuickLogRequest else { return false }
        guard model.presentQuickLogRequest(request) else { return false }
        isShowingWhatsNew = false
        selectedSection = .log
        return true
    }
}
