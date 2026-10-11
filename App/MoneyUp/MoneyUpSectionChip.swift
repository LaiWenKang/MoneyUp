import SwiftUI

/// Explicit horizontal geometry avoids inherited List/toolbar label styles
/// hiding the selected title or proposing a tall, compressed capsule.
struct MoneyUpSectionChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    /// Chips sharing a namespace share one selection highlight, which slides
    /// to the chosen chip instead of fading out on one and in on another.
    var selectionNamespace: Namespace.ID? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                if isSelected {
                    Text(title)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.opacity)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, isSelected ? 14 : 12)
            .frame(minWidth: 44, minHeight: 44)
            .fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(isSelected ? Color.accentColor : .moneyUpSecondary)
            .background {
                ZStack {
                    Capsule().fill(Color.moneyUpSurface)
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    if isSelected { selectionHighlight }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectionHighlight: some View {
        let highlight = ZStack {
            Capsule().fill(Color.accentColor.opacity(0.16))
            Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        }
        if let selectionNamespace {
            highlight.matchedGeometryEffect(id: "moneyup.section-chip.selection", in: selectionNamespace)
        } else {
            highlight
        }
    }
}

extension View {
    /// Navigation owns the title; scroll content and decorative surfaces stay
    /// below it, including on OS versions with translucent navigation chrome.
    func moneyUpNavigationSurface() -> some View {
        modifier(MoneyUpNavigationSurfaceModifier())
    }
}

private struct MoneyUpNavigationSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.moneyUpBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // The navigation controller survives tab and appearance changes.
            // Resolve its foreground from the same scheme as its opaque canvas.
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .tint(Color.accentColor)
    }
}
