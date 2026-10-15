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
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
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
                        for: .disclosure,
                        reduceMotion: reduceMotion
                    )
                ) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                    .font(.callout)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A real 44-pt target; the negative padding keeps section headers
            // at their text height.
            .padding(-13)
            .foregroundStyle(.tint)
            .accessibilityLabel("action.explain")
            .accessibilityHint(explanation)
            .accessibilityValue(
                isExpanded ? "state.expanded" : "state.collapsed"
            )

            if isExpanded {
                Text(explanation)
                    .transition(
                        MoneyUpMotion.disclosureTransition(
                            reduceMotion: reduceMotion
                        )
                    )
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
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                    Group {
                        Divider()
                        detail
                    }
                    .transition(
                        MoneyUpMotion.disclosureTransition(
                            reduceMotion: reduceMotion
                        )
                    )
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(
                MoneyUpMotion.animation(
                    for: .disclosure,
                    reduceMotion: reduceMotion
                )
            ) {
                isExpanded.toggle()
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // The figure takes the card's whole width: beside the badge
                    // and the chevron it was cut to "…" at the largest sizes.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 12) {
                            MoneyUpSymbolBadge(systemImage: systemImage)
                            titleText
                            Spacer(minLength: 8)
                            chevron
                        }
                        summary
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        MoneyUpSymbolBadge(systemImage: systemImage)
                        VStack(alignment: .leading, spacing: 5) {
                            titleText
                            summary
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 8)
                        chevron
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "state.expanded" : "state.collapsed")
        .accessibilityAddTraits(.isButton)
    }

    private var titleText: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.moneyUpSecondary)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// The label stays visible so financial meaning never relies on recognizing
/// an icon. Exact values remain native text and are combined for VoiceOver.
struct MoneyUpFigure: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
            Text(maskingAmounts: value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(MoneyAmountPrivacy.spoken(value))
    }
}
