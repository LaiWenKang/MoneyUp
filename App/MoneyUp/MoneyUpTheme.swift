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
    static let moneyUpChartSeries1 = Color("ChartSeries1")
    static let moneyUpChartSeries2 = Color("ChartSeries2")
    static let moneyUpChartSeries3 = Color("ChartSeries3")
    static let moneyUpChartSeries4 = Color("ChartSeries4")
    static let moneyUpChartSeries5 = Color("ChartSeries5")
    static let moneyUpChartSeries6 = Color("ChartSeries6")
}

/// Stable ordering lets charts reuse a reviewed palette while labels, symbols,
/// geometry, and accessible values continue to carry the actual meaning.
enum MoneyUpChartPalette {
    static let ordered: [Color] = [
        .moneyUpChartSeries1,
        .moneyUpChartSeries2,
        .moneyUpChartSeries3,
        .moneyUpChartSeries4,
        .moneyUpChartSeries5,
        .moneyUpChartSeries6
    ]

    static let income = Color.moneyUpChartSeries1
    static let expense = Color.moneyUpChartSeries2

    static func color(at index: Int) -> Color {
        ordered[index % ordered.count]
    }
}

/// Selection keeps every data mark fully opaque. A high-contrast dashed rule
/// identifies the selected row or month without weakening the 3:1 geometry
/// contrast that the release validator proves for every palette slot.
enum MoneyUpChartSelectionPolicy {
    static let lineWidth: CGFloat = 2
    static let dash: [CGFloat] = [3, 3]
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

enum MoneyUpCardStyle: CaseIterable, Equatable, Sendable {
    case flat
    case raised
    case floating
}

enum MoneyUpCardSurface: Equatable, Sendable {
    case surface
    case elevated
}

enum MoneyUpCardBorderStyle: Equatable, Sendable {
    case gradient
    case solid
}

struct MoneyUpCardAppearance: Equatable, Sendable {
    let surface: MoneyUpCardSurface
    let borderStyle: MoneyUpCardBorderStyle
    let accentBorderOpacity: Double
    let primaryBorderOpacity: Double
    let borderWidth: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowOffsetY: CGFloat
}

enum MoneyUpCardPolicy {
    static let defaultStyle = MoneyUpCardStyle.raised

    static func appearance(
        for style: MoneyUpCardStyle,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> MoneyUpCardAppearance {
        let base = baseAppearance(for: style)
        if reduceTransparency {
            return MoneyUpCardAppearance(
                surface: base.surface,
                borderStyle: .solid,
                accentBorderOpacity: 0,
                primaryBorderOpacity: increaseContrast ? 0.30 : 0.16,
                borderWidth: increaseContrast ? 2 : 1,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowOffsetY: 0
            )
        }
        guard increaseContrast else { return base }
        return MoneyUpCardAppearance(
            surface: base.surface,
            borderStyle: .gradient,
            accentBorderOpacity: max(base.accentBorderOpacity, 0.30),
            primaryBorderOpacity: max(base.primaryBorderOpacity, 0.14),
            borderWidth: 2,
            shadowOpacity: base.shadowOpacity,
            shadowRadius: base.shadowRadius,
            shadowOffsetY: base.shadowOffsetY
        )
    }

    private static func baseAppearance(
        for style: MoneyUpCardStyle
    ) -> MoneyUpCardAppearance {
        switch style {
        case .flat:
            MoneyUpCardAppearance(
                surface: .surface,
                borderStyle: .gradient,
                accentBorderOpacity: 0.10,
                primaryBorderOpacity: 0.05,
                borderWidth: 1,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowOffsetY: 0
            )
        case .raised:
            MoneyUpCardAppearance(
                surface: .elevated,
                borderStyle: .gradient,
                accentBorderOpacity: 0.18,
                primaryBorderOpacity: 0.055,
                borderWidth: 1,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowOffsetY: 0
            )
        case .floating:
            MoneyUpCardAppearance(
                surface: .elevated,
                borderStyle: .gradient,
                accentBorderOpacity: 0.22,
                primaryBorderOpacity: 0.07,
                borderWidth: 1,
                shadowOpacity: 0.12,
                shadowRadius: 18,
                shadowOffsetY: 8
            )
        }
    }
}

struct MoneyUpCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let content: Content
    let style: MoneyUpCardStyle
    let backgroundColor: Color?

    init(
        style: MoneyUpCardStyle = MoneyUpCardPolicy.defaultStyle,
        backgroundColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        let appearance = MoneyUpCardPolicy.appearance(
            for: style,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MoneyUpLayout.cardPadding)
            .background(backgroundColor ?? appearance.surface.color)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MoneyUpLayout.cardRadius,
                    style: .continuous
                )
            )
            .overlay {
                MoneyUpCardBorder(appearance: appearance)
            }
            .modifier(MoneyUpCardShadowModifier(appearance: appearance))
            .accessibilityElement(children: .contain)
    }
}

private struct MoneyUpCardBorder: View {
    let appearance: MoneyUpCardAppearance

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: MoneyUpLayout.cardRadius,
            style: .continuous
        )
    }

    @ViewBuilder
    var body: some View {
        switch appearance.borderStyle {
        case .gradient:
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(
                            appearance.accentBorderOpacity
                        ),
                        Color.primary.opacity(
                            appearance.primaryBorderOpacity
                        )
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: appearance.borderWidth
            )
        case .solid:
            shape.stroke(
                Color.primary.opacity(appearance.primaryBorderOpacity),
                lineWidth: appearance.borderWidth
            )
        }
    }
}

private extension MoneyUpCardSurface {
    var color: Color {
        switch self {
        case .surface: .moneyUpSurface
        case .elevated: .moneyUpSurfaceElevated
        }
    }
}

private struct MoneyUpCardShadowModifier: ViewModifier {
    let appearance: MoneyUpCardAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        if appearance.shadowOpacity > 0 {
            content.shadow(
                color: Color.black.opacity(appearance.shadowOpacity),
                radius: appearance.shadowRadius,
                y: appearance.shadowOffsetY
            )
        } else {
            content
        }
    }
}
