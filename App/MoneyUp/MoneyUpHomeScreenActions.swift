import UIKit

/// Long-pressing the app icon offers the most common ways into Log. Each item
/// carries only the action's name and goes through the same durable, data-free
/// broker as Siri, widgets and controls, so it follows the same covered-book
/// and unlock rules and never records anything by itself.
enum MoneyUpHomeScreenActions {
    static let offered: [MoneyUpQuickAction] = [.expense, .income, .smartEntry, .scanReceipt]
    static let typePrefix = "com.laiwenkang.MoneyUp.quick-action."

    /// Written in the app's current language whenever the app becomes active.
    @MainActor
    static func install(on application: UIApplication = .shared) {
        application.shortcutItems = offered.map { action in
            UIApplicationShortcutItem(
                type: typePrefix + action.rawValue,
                localizedTitle: AppLocalization.string(titleKey(for: action)),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: symbol(for: action)),
                userInfo: nil
            )
        }
    }

    /// Only the offered actions, and only from MoneyUp's own item types.
    static func action(forType type: String) -> MoneyUpQuickAction? {
        guard type.hasPrefix(typePrefix),
              let action = MoneyUpQuickAction(rawValue: String(type.dropFirst(typePrefix.count))),
              offered.contains(action) else { return nil }
        return action
    }

    /// Accepts the action durably; the main scene routes it like a widget tap.
    @MainActor
    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = action(forType: item.type) else { return false }
        return MoneyUpQuickActionRouteBroker.shared.submit(action)
    }

    /// The same reviewed short titles Siri and Spotlight show.
    static func titleKey(for action: MoneyUpQuickAction) -> String {
        switch action {
        case .expense: "shortcut.quick_log.expense"
        case .income: "shortcut.quick_log.income"
        case .transfer: "shortcut.quick_log.transfer"
        case .refund: "shortcut.quick_log.refund"
        case .smartEntry: "shortcut.quick_log.smart_entry"
        case .scanReceipt: "shortcut.quick_log.scan_receipt"
        }
    }

    static func symbol(for action: MoneyUpQuickAction) -> String {
        switch action {
        case .expense: "minus.circle"
        case .income: "plus.circle"
        case .transfer: "arrow.left.arrow.right.circle"
        case .refund: "arrow.uturn.backward.circle"
        case .smartEntry: "sparkles"
        case .scanReceipt: "receipt"
        }
    }
}

/// Receives Home Screen quick actions, which SwiftUI does not surface itself.
final class MoneyUpAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // A quick action that launches the app arrives here, not in the scene.
        if let item = options.shortcutItem {
            MoneyUpHomeScreenActions.perform(item)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = MoneyUpSceneDelegate.self
        return configuration
    }
}

final class MoneyUpSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(MoneyUpHomeScreenActions.perform(shortcutItem))
    }
}
