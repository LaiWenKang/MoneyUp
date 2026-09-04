import SwiftUI

/// A way back out of a screen that a `NavigationStack` did not push.
///
/// MoneyUp's Plan tab swaps whole sections behind a chip bar rather than
/// pushing them, so the system never draws a back button and the only way out
/// is to notice the chips. The section that was swapped in receives this
/// action, and the screen it replaced becomes reachable from the top-left
/// corner where a back control is expected.
///
/// It is handed down explicitly rather than through the environment: the
/// action carries a closure, and a closure is exactly the kind of value an
/// environment key cannot hold without weakening the app's concurrency
/// checking.
struct MoneyUpSectionBackAction {
    /// Names the destination, so the control reads "Overview" rather than a
    /// bare chevron with no announced target.
    let titleKey: LocalizedStringKey
    let perform: () -> Void
}

extension View {
    /// Places the section's back control where a pushed screen would put one.
    ///
    /// Applied inside the section's own navigation container, and inert when
    /// no action is supplied — so the same screen stays correct when it is
    /// genuinely pushed and the system supplies its own back button.
    func moneyUpSectionBackToolbar(
        _ action: MoneyUpSectionBackAction?
    ) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if let action {
                    Button {
                        action.perform()
                    } label: {
                        Label(action.titleKey, systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel(action.titleKey)
                }
            }
        }
    }
}
