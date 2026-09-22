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
