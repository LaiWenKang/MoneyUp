import SwiftUI
import UIKit

@main
@MainActor
struct MoneyUpApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(model)
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
                            || model.requiresAuthenticationPrivacyCover
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
        }
    }
}

private struct ScenePrivacyShield: UIViewRepresentable {
    let isPresented: Bool

    func makeUIView(context: Context) -> PrivacyShieldAnchorView {
        PrivacyShieldAnchorView()
    }

    func updateUIView(
        _ uiView: PrivacyShieldAnchorView,
        context: Context
    ) {
        uiView.setPresented(isPresented)
    }

    static func dismantleUIView(
        _ uiView: PrivacyShieldAnchorView,
        coordinator: ()
    ) {
        uiView.setPresented(false)
    }
}

private final class PrivacyShieldAnchorView: UIView {
    private var isPresented = false
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

    func setPresented(_ presented: Bool) {
        isPresented = presented
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
            shield.backgroundColor = .systemBackground
            shield.isUserInteractionEnabled = true
            let host = UIHostingController(rootView: PrivacyCoverView())
            host.view.backgroundColor = .systemBackground
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
    }
}
