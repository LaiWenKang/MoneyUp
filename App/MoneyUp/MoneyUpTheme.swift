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
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 260, height: 260)
                    .blur(radius: 48)
                    .offset(x: 150, y: -260)

                Circle()
                    .fill(Color.moneyUpMist.opacity(0.14))
                    .frame(width: 220, height: 220)
                    .blur(radius: 56)
                    .offset(x: -170, y: 300)
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

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.moneyUpSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
    }
}
