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

/// The shared upward-growth mark used by the first-run experience and launch
/// surfaces. App icon artwork follows the same three-bar/up-arrow silhouette.
struct MoneyUpGrowthMark: View {
    let color: Color

    init(color: Color = .accentColor) {
        self.color = color
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                HStack(alignment: .bottom, spacing: side * 0.075) {
                    growthBar(height: side * 0.24)
                    growthBar(height: side * 0.40)
                    growthBar(height: side * 0.57)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, side * 0.06)
                .padding(.bottom, side * 0.06)
                .padding(.trailing, side * 0.28)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: side * 0.43, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .offset(x: side * 0.20, y: -side * 0.20)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func growthBar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
            .fill(color)
            .frame(maxWidth: .infinity)
            .frame(height: height)
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
