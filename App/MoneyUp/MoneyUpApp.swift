import SwiftUI

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

                if scenePhase != .active {
                    PrivacyCoverView()
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
                .task {
                    await model.start()
                }
                .onOpenURL { url in
                    model.handleDeepLink(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    model.lock()
                }
        }
    }
}

private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            // Keep the app-switcher snapshot fully opaque. A material can
            // reveal the shape of balances or charts beneath it.
            Color(.systemBackground)
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
