import MoneyUpCore
import SwiftUI

/// Today's one number: what is left this month across the pinned categories,
/// with today's share beneath it. Shown only when every pinned category
/// reports in the same currency, so the figure is never a mixed sum.
struct PinnedRemainingHero: Equatable {
    let remaining: Money
    let today: Money?
    let categoryCount: Int

    static func make(_ summaries: [PinnedBudgetSummary]) -> PinnedRemainingHero? {
        let remaining = summaries.compactMap(\.remaining)
        guard !remaining.isEmpty, remaining.count == summaries.count,
              let currency = remaining.first?.currency,
              remaining.allSatisfy({ $0.currency == currency }) else { return nil }
        var total = Money.zero(currency: currency)
        var todayTotal = Money.zero(currency: currency)
        var hasToday = false
        for summary in summaries {
            guard let value = summary.remaining, let sum = try? total.adding(value) else { return nil }
            total = sum
            if let day = summary.spread?.daily.available, day.currency == currency,
               let daySum = try? todayTotal.adding(day) {
                todayTotal = daySum
                hasToday = true
            }
        }
        return PinnedRemainingHero(remaining: total, today: hasToday ? todayTotal : nil, categoryCount: summaries.count)
    }
}

extension DashboardView {
    @ViewBuilder
    var pinnedRemainingHero: some View {
        if case let .available(summaries) = model.pinnedBudgetSummariesResult(asOf: reportingDate),
           let hero = PinnedRemainingHero.make(summaries) {
            MoneyUpCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label("today.hero.left_month", systemImage: "leaf.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(formattedMoney(hero.remaining))
                        .moneyUpFinancialValue(.hero)
                        .foregroundStyle(hero.remaining.amount < .zero ? Color.moneyUpWarning : .primary)
                    if let today = hero.today {
                        HStack(spacing: 6) {
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(.tint)
                            Text("today.hero.today_share")
                            Text(formattedMoney(today))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("today-pinned-hero")
        }
    }
}

/// A new book's whole to-do list in one card: log something, set a budget.
/// Each step ticks off as it happens, and the card leaves once both are done,
/// so Today never shows the same "set a budget" prompt twice.
struct TodayFirstRunChecklist: View {
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    let hasTransactions: Bool
    let hasBudget: Bool
    let onOpenLog: () -> Void
    let onOpenPlan: () -> Void

    private var completed: Int { (hasTransactions ? 1 : 0) + (hasBudget ? 1 : 0) }

    var body: some View {
        MoneyUpCard(style: .floating) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("today.start.title")
                            .font(.title3.weight(.semibold))
                        Text(String(format: AppLocalization.string("today.start.progress"), completed, 2))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(completed), total: 2)
                            .tint(.moneyUpPositive)
                            .animation(MoneyUpMotion.animation(for: .stateChange, reduceMotion: reduceMotion), value: completed)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    MoneyUpIllustration("MoneyUpMoneyWorld", role: .inline)
                }
                .accessibilityElement(children: .combine)
                step("dashboard.log_first", systemImage: "plus.circle.fill", isDone: hasTransactions, action: onOpenLog)
                step("dashboard.set_budget", systemImage: "chart.pie.fill", isDone: hasBudget, action: onOpenPlan)
            }
        }
        .accessibilityIdentifier("today-first-run-checklist")
    }

    private func step(
        _ title: LocalizedStringKey, systemImage: String, isDone: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : systemImage)
                    .font(.title3)
                    .foregroundStyle(isDone ? Color.moneyUpPositive : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)
                Text(title)
                    .font(.body.weight(isDone ? .regular : .semibold))
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .strikethrough(isDone, color: .secondary)
                Spacer(minLength: 8)
                if !isDone {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                (isDone ? Color.clear : Color.accentColor.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .disabled(isDone)
        .accessibilityValue(isDone ? "state.done" : "state.not_done")
    }
}
