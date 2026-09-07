import SwiftUI
import UIKit
import WidgetKit

@main
@MainActor
struct MoneyUpApp: App {
    @State private var model = AppModel()
    @State private var overviewNavigation = MoneyUpOverviewNavigation()
    @State private var launchState = MoneyUpSceneLaunchState()
    @State private var quickActionRouteBroker =
        MoneyUpQuickActionRouteBroker.shared
    @AppStorage(
        AppLanguagePreference.storageKey,
        store: AppLanguagePreference.defaults
    )
    private var appLanguageRawValue = AppLanguagePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var appLanguage: AppLanguagePreference {
        AppLanguagePreference(rawValue: appLanguageRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(model)
                    .environment(overviewNavigation)
                    .environment(\.locale, appLanguage.locale)
                    .tint(.accentColor)
                    // The opaque cover protects pixels. These modifiers also
                    // remove the underlying financial controls from VoiceOver
                    // and hit testing while the scene is inactive or an
                    // expired auto-lock waits for an atomic write to drain.
                    .accessibilityHidden(
                        scenePhase != .active
                            || model.requiresAuthenticationPrivacyCover
                    )
                    .allowsHitTesting(
                        scenePhase == .active
                            && !model.requiresAuthenticationPrivacyCover
                    )

                if scenePhase != .active
                    || model.requiresAuthenticationPrivacyCover {
                    PrivacyCoverView()
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
                // SwiftUI sheets live in presentation controllers above the
                // root hosting view. Mirror the shield in a scene-level window
                // so an open transaction/receipt/settings sheet cannot remain
                // visible or interactive above the in-tree cover.
                .background {
                    ScenePrivacyShield(
                        isPresented: scenePhase != .active
                            || model.requiresAuthenticationPrivacyCover,
                        locale: appLanguage.locale
                    )
                    .frame(width: 0, height: 0)
                }
                .task {
                    quickActionRouteBroker.reloadDurableIngress()
                    model.retryPresentedQuickActionAcknowledgement()
                    launchState.isActive = scenePhase == .active
                    if scenePhase == .active {
                        // SwiftUI need not emit an initial scenePhase change.
                        // Register the already-active launch before startup so
                        // ready publication can arm the reporting-day refresh.
                        model.sceneDidBecomeActive()
                    }
                    routePendingQuickAction()
                    await startInitialModelIfNeeded()
                    await model.unlockAutomaticallyIfNeeded()
                }
                .onOpenURL { url in
                    routeDeepLink(url)
                }
                .onChange(of: quickActionRouteBroker.revision) { _, _ in
                    routePendingQuickAction()
                }
                .onChange(of: model.isWorking) { _, _ in
                    routePendingQuickAction()
                    Task { await model.unlockAutomaticallyIfNeeded() }
                }
                .onChange(of: model.state) { _, _ in
                    Task { await model.unlockAutomaticallyIfNeeded() }
                }
                .onChange(of: model.isLifecycleMutationInProgress) { _, _ in
                    routePendingQuickAction()
                }
                .onChange(of: model.goalMutationBarrierClosed) { _, _ in
                    routePendingQuickAction()
                }
                .onChange(of: model.requestedQuickLogRequest) { _, request in
                    guard request == nil else { return }
                    routePendingQuickAction()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    launchState.isActive = newPhase == .active
                    switch newPhase {
                    case .background:
                        model.sceneDidEnterBackground()
                    case .active:
                        quickActionRouteBroker.reloadDurableIngress()
                        model.retryPresentedQuickActionAcknowledgement()
                        model.sceneDidBecomeActive()
                        routePendingQuickAction()
                        Task {
                            await startInitialModelIfNeeded()
                            await model.unlockAutomaticallyIfNeeded()
                        }
                    case .inactive:
                        model.sceneDidBecomeInactive()
                    @unknown default:
                        break
                    }
                }
                .onChange(of: appLanguageRawValue) { _, _ in
                    WidgetCenter.shared.reloadAllTimelines()
                }
        }
    }

    private func startInitialModelIfNeeded() async {
        while launchState.claim(isLaunching: model.state == .launching && !model.isWorking) {
            await model.startAfterInitialRoutingWindow(allowProtectedStart: { launchState.isActive })
            let wasDeferred = model.state == .launching && !model.isWorking
            launchState.finish(wasDeferred: wasDeferred)
            if !wasDeferred { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    private func routePendingQuickAction() {
        guard launchState.isActive else { return }
        let result = MoneyUpQuickActionRouting.routeNext(
            from: quickActionRouteBroker,
            into: model
        )
        guard result == .requiresStart else { return }
        Task {
            guard launchState.isActive else { return }
            await model.start()
        }
    }

    private func routeDeepLink(_ url: URL) {
        if let destination = MoneyUpOverviewRoute(exactDeepLink: url) {
            overviewNavigation.request(destination)
            return
        }
        guard let action = MoneyUpQuickAction(exactDeepLink: url) else { return }
        _ = quickActionRouteBroker.submit(action)
        routePendingQuickAction()
    }
}

private struct ScenePrivacyShield: UIViewRepresentable {
    let isPresented: Bool
    let locale: Locale

    func makeUIView(context: Context) -> PrivacyShieldAnchorView {
        PrivacyShieldAnchorView()
    }

    func updateUIView(
        _ uiView: PrivacyShieldAnchorView,
        context: Context
    ) {
        uiView.setPresented(isPresented, locale: locale)
    }

    static func dismantleUIView(
        _ uiView: PrivacyShieldAnchorView,
        coordinator: ()
    ) {
        uiView.setPresented(false, locale: .autoupdatingCurrent)
    }
}

private final class PrivacyShieldAnchorView: UIView {
    private var isPresented = false
    private var localeIdentifier = Locale.autoupdatingCurrent.identifier
    private var shieldWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        synchronizeShield()
    }

    func setPresented(_ presented: Bool, locale: Locale) {
        isPresented = presented
        if localeIdentifier != locale.identifier {
            localeIdentifier = locale.identifier
            shieldWindow?.isHidden = true
            shieldWindow?.rootViewController = nil
            shieldWindow = nil
        }
        synchronizeShield()
    }

    private func synchronizeShield() {
        guard isPresented, let scene = window?.windowScene else {
            shieldWindow?.isHidden = true
            shieldWindow?.rootViewController = nil
            shieldWindow = nil
            return
        }
        if shieldWindow?.windowScene !== scene {
            shieldWindow?.isHidden = true
            let shield = UIWindow(windowScene: scene)
            shield.windowLevel = UIWindow.Level(
                rawValue: UIWindow.Level.normal.rawValue + 1
            )
            let brandBackground = UIColor(named: "BrandBackground") ?? .systemBackground
            shield.backgroundColor = brandBackground
            shield.isUserInteractionEnabled = true
            let host = UIHostingController(
                rootView: PrivacyCoverView()
                    .environment(
                        \.locale,
                        Locale(identifier: localeIdentifier)
                    )
                    .tint(.accentColor)
            )
            host.view.backgroundColor = brandBackground
            host.view.accessibilityViewIsModal = true
            shield.rootViewController = host
            shieldWindow = shield
        }
        shieldWindow?.isHidden = false
    }
}

private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            // Keep the app-switcher snapshot fully opaque. A material can
            // reveal the shape of balances or charts beneath it.
            Color.moneyUpBackground
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("privacy.cover")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(.accentColor)
    }
}
