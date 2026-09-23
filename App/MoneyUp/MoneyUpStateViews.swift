import SwiftUI

/// One visual language for "nothing here yet", "all clear", "could not load",
/// and "working on it" across every screen: a large symbol badge, one short
/// title, one supporting line, and at most one action. The badge carries the
/// mood; the text carries the meaning, so color is never the only signal.
struct MoneyUpStatePlaceholder<Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.moneyUpShowsIllustrations) private var showsIllustrations
    let systemImage: String
    let tint: Color
    let title: Text
    let detail: Text?
    let illustration: String?
    let actions: Actions

    init(
        systemImage: String,
        tint: Color = .accentColor,
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        illustration: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = Text(title)
        self.detail = detail.map { Text($0) }
        self.illustration = illustration
        self.actions = actions()
    }

    /// For titles that are already resolved strings, such as a filter summary.
    init(
        systemImage: String,
        tint: Color = .accentColor,
        title: Text,
        detail: Text? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.detail = detail
        self.illustration = nil
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            // The badge and copy read as one announcement; the action stays
            // its own element so VoiceOver can activate it directly.
            VStack(spacing: 12) {
                if let illustration, showsIllustrations {
                    MoneyUpIllustration(illustration, role: .empty)
                } else {
                    MoneyUpStateBadge(systemImage: systemImage, tint: tint)
                }
                VStack(spacing: 4) {
                    title
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if let detail {
                        detail
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 320)
            }
            .accessibilityElement(children: .combine)
            actions
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 16)
    }
}

/// A larger, softer version of `MoneyUpSymbolBadge` for state placeholders.
struct MoneyUpStateBadge: View {
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.10))
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: 1)
                .padding(6)
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}

/// Inline progress with a label, sized like a placeholder so a screen does not
/// jump when loading resolves into content or an empty state.
struct MoneyUpLoadingPlaceholder: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

/// A section title with its explanation one glyph away, on the same line, so
/// the explainer never floats alone under a card.
struct MoneyUpSectionHeader: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey

    init(_ title: LocalizedStringKey, explanation: LocalizedStringKey) {
        self.title = title
        self.explanation = explanation
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            MoneyUpExplainer(explanation)
                .textCase(nil)
                .font(.footnote)
        }
    }
}
