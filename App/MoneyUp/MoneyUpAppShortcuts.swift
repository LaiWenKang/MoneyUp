import AppIntents

struct MoneyUpAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenQuickLogIntent(action: .expense),
            phrases: ["Log an expense in \(.applicationName)"],
            shortTitle: "shortcut.quick_log.expense",
            systemImageName: "arrow.up.right"
        )
        AppShortcut(
            intent: OpenQuickLogIntent(action: .income),
            phrases: ["Log income in \(.applicationName)"],
            shortTitle: "shortcut.quick_log.income",
            systemImageName: "arrow.down.left"
        )
        AppShortcut(
            intent: OpenQuickLogIntent(action: .transfer),
            phrases: ["Log a transfer in \(.applicationName)"],
            shortTitle: "shortcut.quick_log.transfer",
            systemImageName: "arrow.left.arrow.right"
        )
        AppShortcut(
            intent: OpenQuickLogIntent(action: .refund),
            phrases: ["Log a refund in \(.applicationName)"],
            shortTitle: "shortcut.quick_log.refund",
            systemImageName: "arrow.uturn.backward.circle"
        )
        AppShortcut(
            intent: OpenQuickLogIntent(action: .smartEntry),
            phrases: ["Open Smart Entry in \(.applicationName)"],
            shortTitle: "shortcut.quick_log.smart_entry",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenQuickLogIntent(action: .scanReceipt),
            phrases: ["Choose a receipt in \(.applicationName)"],
            shortTitle: "shortcut.quick_log.scan_receipt",
            systemImageName: "doc.text.viewfinder"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .grayGreen }
}
