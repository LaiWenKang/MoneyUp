import MoneyUpCore
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.quickActionRouteBroker
            .isAuthoritativeLifecycleBoundaryActive {
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
                MainTabView(
                    initialReportingSnapshot: AppReportingSnapshot(
                        instant: model.currentDateForUserAction(),
                        calendar: model.reportingCalendar
                    )
                )
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
    @State private var method: UnlockMethod?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: method?.systemImage ?? "lock.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(
                            method == .unavailable ? Color.orange : Color.accentColor
                        )
                        .accessibilityHidden(true)
                    Text("lock.title")
                        .font(.largeTitle.bold())

                    if let method, method.isAvailable {
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
                    } else if method == .unavailable {
                        // The database key is stored WhenPasscodeSetThisDeviceOnly, so
                        // without a device passcode there is nothing to unlock with.
                        Text("lock.no_passcode")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .padding(32)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background { MoneyUpBackdrop() }
        .task {
            method = await Task.detached(priority: .userInitiated) {
                UnlockMethod.current
            }.value
        }
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
                            systemImage: "externaldrive.badge.checkmark"
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

enum HistoryReturnOrigin: String, Equatable {
    case today
    case log
    case plan
    case assets

    var destination: MoneyUpSection {
        switch self {
        case .today: .today
        case .log: .log
        case .plan: .plan
        case .assets: .assets
        }
    }

    var titleKeyString: String {
        switch self {
        case .today: "tab.today"
        case .log: "tab.log"
        case .plan: "tab.plan"
        case .assets: "tab.assets"
        }
    }

    var backTitle: String {
        String(
            format: AppLocalization.string("history.back_to_format"),
            AppLocalization.string(titleKeyString)
        )
    }
}

/// Process-local authority for a real cross-tab return route. It is never
/// persisted across lock/cold launch and consumption clears it before the tab
/// changes, making repeated taps harmless.
struct HistoryCrossTabNavigationState: Equatable {
    private(set) var origin: HistoryReturnOrigin?

    mutating func record(origin: HistoryReturnOrigin) {
        self.origin = origin
    }

    mutating func clearForDirectTabSelection() {
        origin = nil
    }

    mutating func consumeReturnDestination() -> MoneyUpSection? {
        guard let origin else { return nil }
        self.origin = nil
        return origin.destination
    }
}

struct MainTabView: View {
    @Environment(MoneyUpOverviewNavigation.self) private var overviewNavigation
    @State private var planWorkspace: PlanWorkspaceState
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation: MoneyUpTabNavigation
    private var selectedSection: MoneyUpSection {
        get { navigation.section }
        nonmutating set { navigation.section = newValue }
    }
    @State private var quickLogKind: QuickLogKind = .expense
    @State private var historyReviewDate: Date?
    @State private var historyReviewSequence = 0
    @State private var historyCrossTabNavigation = HistoryCrossTabNavigationState()
    @State private var reportingClock: AppReportingClockState
    @State private var isShowingWhatsNew = false
    @State private var hasCheckedForUpdate = false

    init(
        initialReportingSnapshot: AppReportingSnapshot,
        initialSection: MoneyUpSection = .today,
        initialPlanSection: PlanSection = .budget,
        navigation: MoneyUpTabNavigation? = nil
    ) {
        _navigation = State(initialValue: navigation ?? MoneyUpTabNavigation(section: initialSection))
        _planWorkspace = State(initialValue: PlanWorkspaceState(section: initialPlanSection))
        _reportingClock = State(
            initialValue: AppReportingClockState(
                snapshot: initialReportingSnapshot
            )
        )
    }

    var body: some View {
        TabView(selection: directTabSelection) {
            DashboardView(
                onOpenLog: { selectedSection = .log },
                onOpenPlan: { selectedSection = .plan }
            )
                .tabItem { Label("tab.today", systemImage: "house.fill") }
                .tag(MoneyUpSection.today)

            NavigationStack {
                HistoryView(
                    preset: historyPreset(for: historyReviewDate),
                    returnOrigin: historyCrossTabNavigation.origin,
                    onReturnToOrigin: returnFromHistory
                )
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
                        historyCrossTabNavigation.record(origin: .log)
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

            PlanView(workspace: planWorkspace)
                .tabItem { Label("tab.plan", systemImage: "chart.pie.fill") }
                .tag(MoneyUpSection.plan)

            AssetsView()
                .tabItem { Label("tab.assets", systemImage: "wallet.bifold.fill") }
                .tag(MoneyUpSection.assets)
        }
        .environment(\.appReportingSnapshot, reportingClock.snapshot)
        .environment(\.moneyUpReduceMotion, model.displayPreferences.reducesMotion)
        .environment(\.moneyUpShowsIllustrations, model.displayPreferences.showsIllustrations)
        .background { DisplayPreferenceFailurePresenter() }
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewSheet()
        }
        .onAppear {
            let openedLog = openRequestedLog()
            let openedOverview = openRequestedOverview()
            checkForUpdate(suppressPresentation: openedLog || openedOverview)
            announcePendingRestoreCompletionAfterAppearance()
        }
        .onChange(of: overviewNavigation.pending) { _, _ in
            openRequestedOverview()
        }
        .onChange(of: model.requiresAuthenticationPrivacyCover) { _, _ in
            openRequestedOverview()
        }
        .onChange(of: model.requestedQuickLogRequest) { _, _ in
            openRequestedLog()
        }
        .onChange(of: model.pendingRestoreCompletionAnnouncement) { _, pending in
            guard pending != nil else { return }
            announcePendingRestoreCompletionAfterAppearance()
        }
        .task(id: reportingClockTaskID) {
            await refreshAtReportingBoundaries()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                openRequestedOverview()
                rearmReportingClock()
            } else {
                reportingClock.cancelForInactivity()
            }
        }
        .onChange(of: model.savingsGoals) { _, _ in
            rearmReportingClockIfActive()
        }
        .onChange(of: model.journalProjectionRevision) { _, _ in
            rearmReportingClockIfActive()
        }
        .onChange(of: model.scheduledTransactions) { _, _ in
            rearmReportingClockIfActive()
        }
        .onChange(of: reportingTimeZoneIdentifier) { _, _ in
            rearmReportingClockIfActive()
        }
        .onChange(of: model.restrictedAllowanceProjectionClockIdentity) { _, _ in
            rearmReportingClockIfActive()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification
            )
        ) { _ in
            rearmReportingClockIfActive()
        }
    }

    /// Only TabView's user-driven binding enters here. Programmatic routes
    /// mutate `selectedSection` directly after recording any genuine origin.
    private var directTabSelection: Binding<MoneyUpSection> {
        Binding(
            get: { selectedSection },
            set: { destination in
                MoneyUpKeyboard.dismiss()
                historyCrossTabNavigation.clearForDirectTabSelection()
                selectedSection = destination
            }
        )
    }

    @discardableResult
    private func openRequestedOverview() -> Bool {
        guard let destination = overviewNavigation.consume(
            isReady: model.state == .ready,
            isActive: scenePhase == .active,
            isCovered: model.requiresAuthenticationPrivacyCover
        ) else { return false }
        MoneyUpKeyboard.dismiss()
        isShowingWhatsNew = false
        switch destination {
        case .today: selectedSection = .today
        case .budget:
            planWorkspace.section = .budget
            planWorkspace.budgetDate = nil
            planWorkspace.budgetCurrencyCode = nil
            selectedSection = .plan
        }
        return true
    }

    private func returnFromHistory() {
        guard let destination = historyCrossTabNavigation
            .consumeReturnDestination() else { return }
        selectedSection = destination
    }

    private var reportingTimeZoneIdentifier: String {
        model.reportingCalendar.timeZone.identifier
    }

    private var reportingClockTaskID: String {
        "\(reportingTimeZoneIdentifier):\(reportingClock.generation):\(scenePhase == .active)"
    }

    private func rearmReportingClockIfActive() {
        guard scenePhase == .active else {
            reportingClock.cancelForInactivity()
            return
        }
        rearmReportingClock()
    }

    private func rearmReportingClock() {
        reportingClock.rearm(
            instant: model.currentDateForUserAction(),
            calendar: model.reportingCalendar
        )
    }

    /// One foreground sleeper drives every rolling view. It is cancelled when
    /// the scene leaves active and immediately re-snapshotted on activation.
    @MainActor
    private func refreshAtReportingBoundaries() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            let now = model.currentDateForUserAction()
            let calendar = model.reportingCalendar
            reportingClock.publish(instant: now, calendar: calendar)
            model.refreshRestrictedAllowanceProjectionIfNeeded(asOf: now)
            let scheduledOccurrences = model.scheduledTransactions.compactMap {
                $0.occurrence(onOrAfter: now, calendar: calendar)
            }
            guard let nextRefresh = ReportingClockPolicy.nextRefresh(
                after: now,
                calendar: calendar,
                scheduledOccurrences: scheduledOccurrences,
                restrictedAllowanceChange:
                    model.restrictedAllowanceProjectionExpiry(after: now)
            ) else { return }
            let delay = max(nextRefresh.timeIntervalSince(now), 0.001)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
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
