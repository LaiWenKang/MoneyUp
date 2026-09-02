import AppIntents
import SwiftUI
import WidgetKit

struct MoneyUpQuickLogControl: ControlWidget {
    let kind = "com.laiwenkang.MoneyUp.QuickLogControl"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: kind,
            intent: OpenQuickLogIntent.self
        ) { configuration in
            ControlWidgetButton(action: configuration) {
                Label {
                    Text(configuration.action.titleKey)
                } icon: {
                    Image(systemName: configuration.action.systemImage)
                }
            }
        }
        .displayName("control.quick_log.display_name")
        .description("control.quick_log.description")
    }
}
