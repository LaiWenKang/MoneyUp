import SwiftUI

/// The closed set of collapsible surfaces whose expansion state is remembered
/// between launches.
///
/// Every identifier describes screen furniture only. No category, account,
/// payee, amount, or other book content ever becomes a preference key, so
/// remembering how a person likes their screen laid out stays outside the
/// encrypted-data boundary by construction rather than by review.
enum MoneyUpDisclosureSection: String, CaseIterable, Sendable {
    case todayPosition = "moneyup.disclosure.today-position"
    case todayBudget = "moneyup.disclosure.today-budget"
    case todayPinnedDetail = "moneyup.disclosure.today-pinned-detail"
    case planBudgetDetail = "moneyup.disclosure.plan-budget-detail"
}

/// Supporting prose that stays out of the way until it is asked for.
///
/// A screen that explains itself in a paragraph nobody is reading costs the
/// same attention every visit. The words are kept — they move behind one
/// glyph, and remain immediately available to VoiceOver as a hint, so nothing
/// is hidden from the people most likely to need it.
struct MoneyUpExplainer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private let explanation: LocalizedStringKey

    init(_ explanation: LocalizedStringKey) {
        self.explanation = explanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(
                    MoneyUpMotion.animation(
                        for: .stateChange,
                        reduceMotion: reduceMotion
                    )
                ) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                    .font(.callout)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("action.explain")
            .accessibilityHint(explanation)
            .accessibilityValue(
                isExpanded ? "state.expanded" : "state.collapsed"
            )

            if isExpanded {
                Text(explanation)
            }
        }
    }
}

/// A card that leads with one figure and keeps its supporting rows one tap
/// away.
///
/// The summary is what a person came to read; the detail is what they check
/// occasionally. Collapsing the second by default is what lets a screen show
/// several subjects at once without any of them becoming a paragraph.
struct MoneyUpDisclosureCard<Summary: View, Detail: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var isExpanded: Bool

    private let systemImage: String
    private let title: LocalizedStringKey
    private let summary: Summary
    private let detail: Detail

    init(
        section: MoneyUpDisclosureSection,
        systemImage: String,
        title: LocalizedStringKey,
        startsExpanded: Bool = false,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder detail: () -> Detail
    ) {
        _isExpanded = AppStorage(
            wrappedValue: startsExpanded,
            section.rawValue
        )
        self.systemImage = systemImage
        self.title = title
        self.summary = summary()
        self.detail = detail()
    }

    var body: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                if isExpanded {
                    Divider()
                    detail
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(
                MoneyUpMotion.animation(
                    for: .stateChange,
                    reduceMotion: reduceMotion
                )
            ) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                MoneyUpSymbolBadge(systemImage: systemImage)
                summary
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "state.expanded" : "state.collapsed")
        .accessibilityAddTraits(.isButton)
    }
}

/// One figure with a symbol instead of a caption naming it.
///
/// The symbol carries the meaning on screen and the name is preserved for
/// VoiceOver, which is how a row of positions fits on one line without
/// becoming a list of labelled sentences.
struct MoneyUpFigure: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
            // At accessibility sizes the symbol alone stops being a reliable
            // label, so the name it stands for comes back on screen.
            if dynamicTypeSize.isAccessibilitySize {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
