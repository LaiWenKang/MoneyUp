import SwiftUI

/// MoneyUp's visual system is expressed with semantic assets so light, dark,
/// increased-contrast, and future tinted appearances can evolve without
/// scattering literal colours through financial screens.
extension Color {
    static let moneyUpPositive = Color("ChartSeries1")
    static let moneyUpWarning = Color("ChartSeries3")
    static let moneyUpDanger = Color("ChartSeries5")
    static let moneyUpBackground = Color("BrandBackground")
    static let moneyUpSurface = Color("BrandSurface")
    static let moneyUpSurfaceElevated = Color("BrandSurfaceElevated")
    static let moneyUpAction = Color("BrandAction")
    static let moneyUpMist = Color("BrandMist")
    /// Secondary text: at least 4.5:1 on every MoneyUp canvas. The system grey
    /// measures 4.0:1 on a white card.
    static let moneyUpSecondaryText = Color("BrandTextSecondary")
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

    /// Identity colours for things that carry no status, such as savings
    /// goals: the palette without its warning (3) and danger (5) slots, so an
    /// identity is never read as an alert. Stable per identifier.
    static let identity: [Color] = [
        .moneyUpChartSeries1, .moneyUpChartSeries2, .moneyUpChartSeries4, .moneyUpChartSeries6
    ]

    static func identityColor(for id: UUID) -> Color {
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return identity[hash % identity.count]
    }

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
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // No accessibility modifier: colors, gradients and shapes carry no
        // accessibility content, so nothing here reaches VoiceOver. An
        // explicit accessibilityHidden made SwiftUI create a node for the
        // backdrop, which the iOS 26 audit reported on the lock screen as an
        // unlabelled element as wide as its offset glows.
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
    let isHero: Bool

    /// - Parameter isHero: The screen's lead card, on `MoneyUpHeroSurface`.
    init(
        style: MoneyUpCardStyle = MoneyUpCardPolicy.defaultStyle,
        backgroundColor: Color? = nil,
        isHero: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.backgroundColor = backgroundColor
        self.isHero = isHero
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
            .background {
                if isHero {
                    MoneyUpHeroSurface()
                } else {
                    backgroundColor ?? appearance.surface.color
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MoneyUpLayout.cardRadius,
                    style: .continuous
                )
            )
            .overlay {
                MoneyUpCardBorder(appearance: appearance)
                    .allowsHitTesting(false)
            }
            .modifier(MoneyUpCardShadowModifier(appearance: appearance))
            .accessibilityElement(children: .contain)
    }
}

/// The lead card of a screen: the mist tint washes in from the top corner over
/// the elevated surface. Its strength stays within the half-strength mist the
/// release validator proves secondary text against.
struct MoneyUpHeroSurface: View {
    static let mistOpacity = 0.45

    var body: some View {
        LinearGradient(
            colors: [Color.moneyUpMist.opacity(Self.mistOpacity), Color.moneyUpMist.opacity(0)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(Color.moneyUpSurfaceElevated)
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

/// A text field set into its card as a shallow well of the page colour. The
/// system rounded border draws a pure black box on dark cards; this one reads
/// as part of the card in both appearances and keeps a 44-pt target.
private struct MoneyUpInsetFieldModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(Color.moneyUpBackground, in: shape)
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.5 : 0.14),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func moneyUpInsetField() -> some View {
        modifier(MoneyUpInsetFieldModifier())
    }
}

extension ShapeStyle where Self == Color {
    /// Secondary text and glyphs. Used instead of `.secondary`, whose grey is
    /// 4.0:1 on a white card. (Setting it as the app's second foreground level
    /// instead would also take the tint off every plain button.)
    static var moneyUpSecondary: Color { .moneyUpSecondaryText }
}
