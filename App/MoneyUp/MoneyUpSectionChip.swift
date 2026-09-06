import SwiftUI

/// Explicit horizontal geometry avoids inherited List/toolbar label styles
/// hiding the selected title or proposing a tall, compressed capsule.
struct MoneyUpSectionChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
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
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.moneyUpSurface,
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08),
                    lineWidth: 1
                ).allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// Navigation owns the title; scroll content and decorative surfaces stay
    /// below it, including on OS versions with translucent navigation chrome.
    func moneyUpNavigationSurface() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.moneyUpBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
