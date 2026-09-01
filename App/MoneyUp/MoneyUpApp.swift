import SwiftUI
import UIKit
import WidgetKit

@main
@MainActor
struct MoneyUpApp: App {
    @State private var model = AppModel()
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
                    await model.startAfterInitialRoutingWindow()
                }
                .onOpenURL { url in
                    guard model.handleDeepLink(url), model.state == .locked else { return }
                    guard !model.canPresentLockedQuickCapture else { return }
                    Task { await model.start() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        model.sceneDidEnterBackground()
                    case .active:
                        model.sceneDidBecomeActive()
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
