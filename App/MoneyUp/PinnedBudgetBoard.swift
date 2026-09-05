import MoneyUpCore
import SwiftUI

/// The Today board of categories the user chose to watch.
///
/// It replaces the general-purpose "flexible today" hero with the specific
/// categories a person actually steers by, and states each one's remaining
/// balance for the month alongside the even split of that balance across the
/// coming week and the current day.
struct PinnedBudgetBoard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    /// One switch for the whole board rather than one per category: the
    /// question "how am I doing against the limit" is asked of every pinned
    /// row at once, or of none.
    @AppStorage(MoneyUpDisclosureSection.todayPinnedDetail.rawValue)
    private var showsDetail = false
    let reportingDate: Date
    let monthElapsed: Double
    let onOpenPlan: () -> Void
    @Binding var isEditingPins: Bool

    var body: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 14) {
                header

                switch model.pinnedBudgetSummariesResult(asOf: reportingDate) {
                case let .available(summaries) where summaries.isEmpty:
                    emptyState
                case let .available(summaries):
                    ForEach(summaries) { summary in
                        PinnedBudgetRow(
                            summary: summary,
                            monthElapsed: monthElapsed,
                            showsDetail: showsDetail
                        )
                        if summary.id != summaries.last?.id { Divider() }
                    }
                    if summaries.count < model.pinnedBudgetNodes.count {
                        Text("today.pinned.missing_categories")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case let .unavailable(issue):
                    DerivedValueUnavailableView(issue: issue, prominent: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Label("today.pinned.title", systemImage: "pin.fill")
                .font(.headline)
            Spacer(minLength: 8)
            Button {
                withAnimation(
                    MoneyUpMotion.animation(
                        for: .stateChange,
                        reduceMotion: reduceMotion
                    )
                ) {
                    showsDetail.toggle()
                }
            } label: {
                Label("display.details", systemImage: "text.alignleft")
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("today.pinned.toggle_detail")
            .accessibilityValue(
                showsDetail ? "state.expanded" : "state.collapsed"
            )

            Button {
                isEditingPins = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("today.pinned.edit")
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.budgetNodes.isEmpty {
            Text("today.pinned.needs_budget")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                onOpenPlan()
            } label: {
                Label("dashboard.set_budget", systemImage: "chart.pie.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.moneyUpAction)
        } else {
            Text("today.pinned.empty_detail")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isEditingPins = true
            } label: {
                Label("today.pinned.choose", systemImage: "pin")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.moneyUpAction)
        }
    }
}

/// One pinned category: what is left this month, and how that divides across
/// the shorter horizons, in a deliberately quieter type size.
struct PinnedBudgetRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let summary: PinnedBudgetSummary
    let monthElapsed: Double
    /// Board-wide: the purpose chip and the spent-against-limit split are a
    /// periodic check, not part of reading what is left.
    let showsDetail: Bool

    private var ratio: DerivedValue<Double>? {
        guard let limit = summary.effectiveLimit else { return nil }
        return moneyUpPaceRatio(
            spent: summary.spent.amount,
            limit: limit.amount,
            operation: "pinned-budget-row-ratio"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headline
            if case let .available(value)? = ratio {
                MoneyUpPaceBar(
                    ratio: value,
                    elapsed: monthElapsed,
                    announcesStatus: false
                )
            } else if case let .unavailable(issue)? = ratio {
                DerivedValueUnavailableView(issue: issue)
            }
            if model.displayPreferences.showsGuidance(for: summary.id) { cadences }
            if showsDetail { footnote }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(summary.node.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            if let remaining = summary.remaining {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(
                        formattedMoney(
                            summary.isOverspent ? remaining.negated : remaining
                        )
                    )
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(summary.isOverspent ? Color.red : Color.primary)
                    Text(summary.isOverspent ? "plan.over" : "plan.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(formattedMoney(summary.spent))
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private var cadences: some View {
        if let spread = summary.spread {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    cadence("today.pinned.month", spread.monthly.available)
                    cadence("today.pinned.week", spread.weekly.available)
                    cadence("today.pinned.day", spread.daily.available)
                }
            } else {
                HStack(spacing: 12) {
                    cadence("today.pinned.month", spread.monthly.available)
                    cadence("today.pinned.week", spread.weekly.available)
                    cadence("today.pinned.day", spread.daily.available)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func cadence(_ titleKey: LocalizedStringKey, _ money: Money) -> some View {
        HStack(spacing: 3) {
            Text(titleKey)
                .foregroundStyle(.secondary)
            Text(formattedMoney(money))
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.caption2)
    }

    /// Names the category's purpose beside the spend so an even split shown for
    /// a commitment is never mistaken for discretionary money.
    private var footnote: some View {
        HStack(spacing: 8) {
            Label(summary.purpose.titleKey, systemImage: summary.purpose.systemImage)
                .foregroundStyle(
                    summary.purpose == .unclassified
                        ? Color.orange
                        : Color.accentColor
                )
            if let limit = summary.effectiveLimit {
                Text(
                    String(
                        format: AppLocalization.string("plan.spent_of_limit"),
                        formattedMoney(summary.spent),
                        formattedMoney(limit)
                    )
                )
                .foregroundStyle(.secondary)
            } else {
                Text("today.pinned.no_limit")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }
}
