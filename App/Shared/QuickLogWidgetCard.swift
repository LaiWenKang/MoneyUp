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
    /// A square tile in the large widget's grid: glyph above, label below.
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
///
/// One rule shapes every size: a single green action, then plain labelled
/// rows. One container per tile, one glyph weight, no decoration.
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

    private var shortcuts: [MoneyUpQuickAction] {
        Self.shortcuts(for: primary, family: family, density: density)
    }

    var body: some View {
        switch family {
        case .small:
            tile(primary, .canvas)
        case .medium:
            HStack(spacing: 8) {
                tile(primary, .hero)
                if !shortcuts.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(shortcuts) { action in tile(action, .shortcutRow) }
                    }
                }
            }
        case .large where density == .accessibility || shortcuts.count != 5:
            VStack(spacing: 6) {
                tile(primary, .hero)
                ForEach(shortcuts) { action in tile(action, .shortcutRow) }
            }
        case .large:
            // A 3-column grid: the main action spans two columns beside two
            // tiles, and three tiles run beneath. Every cell is a target and
            // no slot is left empty.
            GeometryReader { proxy in
                let gap: CGFloat = 8
                let column = (proxy.size.width - gap * 2) / 3
                let topHeight = (proxy.size.height - gap) * 0.56
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        tile(primary, .hero).frame(width: column * 2 + gap)
                        VStack(spacing: gap) {
                            tile(shortcuts[0], .shortcutTile)
                            tile(shortcuts[1], .shortcutTile)
                        }
                        .frame(width: column)
                    }
                    .frame(height: topHeight)
                    HStack(spacing: gap) {
                        ForEach(shortcuts.suffix(3)) { action in
                            tile(action, .shortcutTile).frame(width: column)
                        }
                    }
                }
            }
        }
    }
}

/// One tile. It never renders an amount, account, payee, or other book data;
/// the label names the consequence of the tap.
struct QuickLogWidgetTile: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let action: MoneyUpQuickAction
    let role: QuickLogWidgetTileRole

    private var isFullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        Group {
            switch role {
            case .canvas: heroContent(glyphSize: 40).padding(2)
            case .hero:
                heroContent(glyphSize: 34)
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isFullColor ? AnyShapeStyle(QuickLogWidgetPalette.heroGradient)
                                : AnyShapeStyle(Color.primary.opacity(0.12)))
                    }
            case .shortcutRow: shortcutRow
            case .shortcutTile: shortcutTile
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QuickLogWidgetCopy.heroTitle(action)))
        .accessibilityHint(action.accessibilityHintKey)
    }

    /// Mark at the top, verb at the bottom. Nothing else competes.
    private func heroContent(glyphSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            QuickLogWidgetHeroMark(action: action, size: glyphSize, isFullColor: isFullColor)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(QuickLogWidgetCopy.heroTitle(action))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                if action.requiresUnlock {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                        .opacity(0.7)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(isFullColor ? Color.white : Color.primary)
    }

    private var shortcutTile: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFullColor ? QuickLogWidgetPalette.accentInk : Color.primary)
                    .widgetAccentable()
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                // The unlock mark sits in the corner so the label never
                // truncates to make room for it.
                if action.requiresUnlock {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 4)
            Text(action.titleKey)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFullColor ? QuickLogWidgetPalette.shortcutFill : Color.primary.opacity(0.08))
        }
    }

    private var shortcutRow: some View {
        HStack(spacing: 10) {
            Image(systemName: action.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFullColor ? QuickLogWidgetPalette.accentInk : Color.primary)
                .frame(width: 20)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text(action.titleKey)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if action.requiresUnlock {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFullColor ? QuickLogWidgetPalette.shortcutFill : Color.primary.opacity(0.08))
        }
    }
}

/// One solid disc with the glyph cut in: a single mark, not a plate holding an
/// icon. Tinted and accented modes fall back to the bare glyph.
struct QuickLogWidgetHeroMark: View {
    let action: MoneyUpQuickAction
    let size: CGFloat
    let isFullColor: Bool

    var body: some View {
        Group {
            if isFullColor {
                Image(systemName: action.systemImage)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(QuickLogWidgetPalette.heroBottom)
                    .frame(width: size, height: size)
                    .background(Color.white, in: Circle())
            } else {
                Image(systemName: action.systemImage)
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .frame(width: size, height: size, alignment: .leading)
                    .widgetAccentable()
            }
        }
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
}

/// MoneyUp's deep green (#34785F) and mint (#82CEAE) expressed as adaptive
/// widget tokens. White hero text keeps at least 4.5:1 on both gradient ends;
/// the shortcut glyph keeps at least 3:1 on its row.
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
        light: (0xEC, 0xF3, 0xEF), dark: (0x22, 0x2E, 0x28),
        highContrastLight: (0xE1, 0xEE, 0xE7), highContrastDark: (0x1C, 0x2A, 0x23)
    ))
    static let accentInk = Color(uiColor: adaptive(
        light: (0x34, 0x78, 0x5F), dark: (0x82, 0xCE, 0xAE),
        highContrastLight: (0x1F, 0x60, 0x47), highContrastDark: (0xA4, 0xE7, 0xCA)
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
