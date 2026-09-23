import SwiftUI
import UIKit
import WidgetKit

/// Where a Quick Log widget tile sits. The hero is the one dominant action;
/// shortcuts are stable, labelled, and visibly secondary.
enum QuickLogWidgetTileRole: Equatable, Sendable {
    /// The whole small widget is the action; the canvas supplies the colour.
    case canvas
    case hero
    case shortcutRow
    case shortcutTile
}

enum QuickLogWidgetLayoutFamily: Equatable, Sendable {
    case small
    case medium
    case large
}

/// Data-free composition shared by the widget extension and the in-app
/// preview. It receives only the closed action enum; the caller decides how a
/// tile becomes interactive, so every navigation link stays in the widget file.
struct QuickLogWidgetCard<Tile: View>: View {
    let primary: MoneyUpQuickAction
    let family: QuickLogWidgetLayoutFamily
    let density: MoneyUpWidgetHomeDensity
    let tile: (MoneyUpQuickAction, QuickLogWidgetTileRole) -> Tile

    /// A stable order. Pinned positions never move with usage, so the thumb
    /// learns where each shortcut lives.
    nonisolated static func shortcuts(
        for primary: MoneyUpQuickAction,
        family: QuickLogWidgetLayoutFamily,
        density: MoneyUpWidgetHomeDensity
    ) -> [MoneyUpQuickAction] {
        switch (family, density) {
        case (.small, _), (.medium, .accessibility):
            return []
        case (.medium, .standard):
            return Array(MoneyUpQuickAction.mediumActions(preferred: primary).dropFirst())
        case (.large, .accessibility):
            return Array(MoneyUpQuickAction.mediumActions(preferred: primary).dropFirst().prefix(2))
        case (.large, .standard):
            return MoneyUpQuickAction.allCases.filter { $0 != primary }
        }
    }

    nonisolated static func rows(
        of actions: [MoneyUpQuickAction], size: Int
    ) -> [[MoneyUpQuickAction]] {
        stride(from: 0, to: actions.count, by: size).map {
            Array(actions[$0..<min($0 + size, actions.count)])
        }
    }

    private var shortcuts: [MoneyUpQuickAction] {
        Self.shortcuts(for: primary, family: family, density: density)
    }

    var body: some View {
        switch family {
        case .small:
            tile(primary, .canvas)
        case .medium:
            HStack(spacing: 10) {
                tile(primary, .hero)
                if !shortcuts.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(shortcuts) { action in tile(action, .shortcutRow) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        case .large:
            VStack(spacing: 8) {
                tile(primary, .hero)
                if density == .accessibility {
                    ForEach(shortcuts) { action in tile(action, .shortcutRow) }
                } else {
                    // Rows of three; a shorter last row widens its tiles
                    // instead of leaving an empty, tappable-looking hole.
                    ForEach(Self.rows(of: shortcuts, size: 3), id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(row) { action in tile(action, .shortcutTile) }
                        }
                    }
                }
            }
        }
    }
}

/// One tile's artwork. It never renders an amount, account, payee, or other
/// book data; the label names the consequence of the tap.
struct QuickLogWidgetTile: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let action: MoneyUpQuickAction
    let role: QuickLogWidgetTileRole

    private var isFullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        Group {
            switch role {
            case .canvas: canvas
            case .hero: hero
            case .shortcutRow: shortcutRow
            case .shortcutTile: shortcutTile
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QuickLogWidgetCopy.heroTitle(action)))
        .accessibilityHint(action.accessibilityHintKey)
    }

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                QuickLogWidgetGlyph(action: action, size: 44, onColor: true)
                Spacer(minLength: 0)
                QuickLogWidgetBrandMark(onColor: true)
            }
            Spacer(minLength: 6)
            heroText(titleFont: .system(.title3, design: .rounded, weight: .bold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(isFullColor ? Color.white : Color.primary)
        .contentShape(Rectangle())
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                QuickLogWidgetGlyph(action: action, size: 38, onColor: true)
                Spacer(minLength: 0)
                QuickLogWidgetBrandMark(onColor: true)
            }
            Spacer(minLength: 6)
            heroText(titleFont: .system(.headline, design: .rounded, weight: .bold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(isFullColor ? Color.white : Color.primary)
        .background {
            QuickLogWidgetHeroSurface(isFullColor: isFullColor)
                .overlay(alignment: .bottomTrailing) {
                    if isFullColor {
                        // A quiet, oversized echo of the action symbol gives the
                        // hero depth without a chart or number to misread.
                        Image(systemName: action.systemImage)
                            .font(.system(size: 88, weight: .bold))
                            .foregroundStyle(.white.opacity(0.07))
                            .offset(x: 14, y: 18)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func heroText(titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(QuickLogWidgetCopy.heroTitle(action))
                .font(titleFont)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.85)
            if !dynamicTypeSize.isAccessibilitySize {
                Label {
                    Text(QuickLogWidgetCopy.heroDetail(action))
                } icon: {
                    Image(systemName: action.requiresUnlock ? "lock.fill" : "keyboard")
                }
                .font(.caption2.weight(.semibold))
                .opacity(0.82)
                .lineLimit(1)
            }
        }
    }

    private var shortcutRow: some View {
        HStack(spacing: 8) {
            QuickLogWidgetGlyph(action: action, size: 26, onColor: false)
            Text(action.titleKey)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { QuickLogWidgetShortcutSurface(isFullColor: isFullColor) }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shortcutTile: some View {
        VStack(spacing: 6) {
            QuickLogWidgetGlyph(action: action, size: 32, onColor: false)
            Text(action.titleKey)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background { QuickLogWidgetShortcutSurface(isFullColor: isFullColor) }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The small widget's full-bleed background, and the medium/large hero's fill.
struct QuickLogWidgetHeroSurface: View {
    let isFullColor: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if isFullColor {
            shape
                .fill(QuickLogWidgetPalette.heroGradient)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.30), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
        } else {
            shape.fill(Color.primary.opacity(0.10))
                .overlay { shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1) }
        }
    }
}

struct QuickLogWidgetShortcutSurface: View {
    let isFullColor: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape
            .fill(isFullColor ? QuickLogWidgetPalette.shortcutFill : Color.primary.opacity(0.08))
            .overlay {
                shape.strokeBorder(
                    isFullColor ? QuickLogWidgetPalette.shortcutStroke : Color.primary.opacity(0.22),
                    lineWidth: 1
                )
            }
    }
}

/// A consistent symbol plate: one stroke weight and optical size per role.
struct QuickLogWidgetGlyph: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let action: MoneyUpQuickAction
    let size: CGFloat
    let onColor: Bool

    var body: some View {
        let isFullColor = renderingMode == .fullColor
        ZStack {
            Circle().fill(
                !isFullColor ? Color.primary.opacity(0.14)
                    : onColor ? Color.white.opacity(0.20) : QuickLogWidgetPalette.glyphPlate
            )
            Image(systemName: action.systemImage)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(
                    !isFullColor ? Color.primary
                        : onColor ? Color.white : QuickLogWidgetPalette.glyphInk
                )
                .widgetAccentable()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A quiet signature in the hero corner instead of a competing header.
struct QuickLogWidgetBrandMark: View {
    let onColor: Bool

    var body: some View {
        Image("MoneyUpBrandMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .opacity(onColor ? 0.55 : 0.4)
            .accessibilityHidden(true)
    }
}

enum QuickLogWidgetCopy {
    static func heroTitle(_ action: MoneyUpQuickAction) -> LocalizedStringKey {
        switch action {
        case .expense: "widget.hero.expense"
        case .income: "widget.hero.income"
        case .transfer: "widget.hero.transfer"
        case .refund: "widget.hero.refund"
        case .smartEntry: "widget.hero.smart_entry"
        case .scanReceipt: "widget.hero.scan_receipt"
        }
    }

    static func heroDetail(_ action: MoneyUpQuickAction) -> LocalizedStringKey {
        switch action {
        case .expense, .income, .refund: "widget.hero.detail_amount"
        case .transfer: "widget.hero.detail_transfer"
        case .smartEntry, .scanReceipt: "platform_action.unlock_required"
        }
    }
}

/// MoneyUp's deep green (#34785F) and mint (#82CEAE) expressed as adaptive
/// widget tokens. White hero text keeps at least 4.5:1 on both gradient ends.
enum QuickLogWidgetPalette {
    static let heroTop = Color(uiColor: adaptive(
        light: (0x34, 0x78, 0x5F), dark: (0x2F, 0x76, 0x5B),
        highContrastLight: (0x24, 0x5F, 0x49), highContrastDark: (0x26, 0x63, 0x4C)
    ))
    static let heroBottom = Color(uiColor: adaptive(
        light: (0x25, 0x5C, 0x48), dark: (0x1D, 0x4A, 0x39),
        highContrastLight: (0x17, 0x4A, 0x37), highContrastDark: (0x17, 0x40, 0x31)
    ))
    static let heroGradient = LinearGradient(
        colors: [heroTop, heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let shortcutFill = Color(uiColor: adaptive(
        light: (0xEA, 0xF3, 0xEE), dark: (0x22, 0x31, 0x2A),
        highContrastLight: (0xE1, 0xEE, 0xE7), highContrastDark: (0x1C, 0x2A, 0x23)
    ))
    static let shortcutStroke = Color(uiColor: adaptive(
        light: (0xD2, 0xE6, 0xDB), dark: (0x33, 0x4A, 0x3F),
        highContrastLight: (0x34, 0x78, 0x5F), highContrastDark: (0x82, 0xCE, 0xAE)
    ))
    static let glyphPlate = Color(uiColor: adaptive(
        light: (0x34, 0x78, 0x5F), dark: (0x82, 0xCE, 0xAE),
        highContrastLight: (0x1F, 0x60, 0x47), highContrastDark: (0xA4, 0xE7, 0xCA)
    ))
    static let glyphInk = Color(uiColor: adaptive(
        light: (0xFF, 0xFF, 0xFF), dark: (0x10, 0x2B, 0x20),
        highContrastLight: (0xFF, 0xFF, 0xFF), highContrastDark: (0x0B, 0x1F, 0x17)
    ))

    private typealias RGB = (Int, Int, Int)

    private static func adaptive(
        light: RGB, dark: RGB, highContrastLight: RGB, highContrastDark: RGB
    ) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb: RGB = traits.accessibilityContrast == .high
                ? (isDark ? highContrastDark : highContrastLight)
                : (isDark ? dark : light)
            return UIColor(
                red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                blue: CGFloat(rgb.2) / 255, alpha: 1
            )
        }
    }
}
