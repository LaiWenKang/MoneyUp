import SwiftUI

@main
@MainActor
struct MoneyUpApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
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
