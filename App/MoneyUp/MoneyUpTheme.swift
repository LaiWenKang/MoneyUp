import SwiftUI

/// MoneyUp's visual system is expressed with semantic assets so light, dark,
/// increased-contrast, and future tinted appearances can evolve without
/// scattering literal colours through financial screens.
extension Color {
    static let moneyUpBackground = Color("BrandBackground")
    static let moneyUpSurface = Color("BrandSurface")
    static let moneyUpSurfaceElevated = Color("BrandSurfaceElevated")
    static let moneyUpAction = Color("BrandAction")
    static let moneyUpMist = Color("BrandMist")
}

/// A deliberately small layout scale for the surfaces touched most often.
/// Keeping these values semantic lets cards, forms, and empty states become
/// more consistent without replacing native SwiftUI controls.
enum MoneyUpLayout {
    static let compactSpacing: CGFloat = 8
    static let standardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 18
    static let cardRadius: CGFloat = 22
    static let heroRadius: CGFloat = 26
    static let readableContentWidth: CGFloat = 620
}

/// A calm, adaptive canvas. Decorative layers never carry information and are
/// intentionally restrained when transparency is reduced.
struct MoneyUpBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        ZStack {
            Color.moneyUpBackground

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.10 : 0.16),
                    Color.moneyUpMist.opacity(reduceTransparency ? 0.08 : 0.20),
                    Color.moneyUpBackground.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if !reduceTransparency {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.13), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 140
                        )
                    )
                    .frame(width: 300, height: 240)
                    .offset(x: 150, y: -270)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color.moneyUpMist.opacity(0.18), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 130
                        )
                    )
                    .frame(width: 280, height: 250)
                    .offset(x: -170, y: 310)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// MoneyUp's shared horned-money emblem. The three ascending pillars read as
/// folded banknotes while the upper silhouette nods to CowCome without turning
/// the product into a cartoon mascot.
struct MoneyUpBrandMark: View {
    let color: Color

    init(color: Color = .accentColor) {
        self.color = color
    }

    var body: some View {
        Image("MoneyUpBrandMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

struct MoneyUpCard<Content: View>: View {
    let content: Content
    let backgroundColor: Color

    init(
        backgroundColor: Color = .moneyUpSurfaceElevated,
        @ViewBuilder content: () -> Content
    ) {
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MoneyUpLayout.cardPadding)
            .background(backgroundColor)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MoneyUpLayout.cardRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: MoneyUpLayout.cardRadius,
                    style: .continuous
                )
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.primary.opacity(0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .accessibilityElement(children: .contain)
    }
}
