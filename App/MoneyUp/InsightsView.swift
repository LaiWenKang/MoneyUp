import Charts
import MoneyUpCore
import SwiftUI

struct InsightsView: View {
    private struct CategoryPoint: Identifiable {
        let id: UUID
        let name: String
        let amount: Double
    }

    private struct CashFlowPoint: Identifiable {
        let id = UUID()
        let month: Date
        let series: String
        let amount: Double
    }

    @EnvironmentObject private var model: AppModel

    private var currentMonthInterval: DateInterval? {
        Calendar.current.dateInterval(of: .month, for: Date())
    }

    private var currentTotals: (income: Money, expense: Money, net: Money)? {
        guard let currency = model.profile?.baseCurrency,
              let interval = currentMonthInterval else { return nil }
        let income = (try? FinanceCalculator.total(
            for: .income,
            accounts: model.accounts,
            entries: model.entries,
            currency: currency,
            interval: interval
        )) ?? Money.zero(currency: currency)
        let expense = (try? FinanceCalculator.total(
            for: .expense,
            accounts: model.accounts,
            entries: model.entries,
            currency: currency,
            interval: interval
        )) ?? Money.zero(currency: currency)
        return (income, expense, (try? income.subtracting(expense)) ?? Money.zero(currency: currency))
    }

    private var categoryPoints: [CategoryPoint] {
        model.spendingThisMonth().compactMap { id, money in
            guard money.amount > .zero,
                  let account = model.accounts.first(where: { $0.id == id }) else { return nil }
            return CategoryPoint(
                id: id,
                name: account.name,
                amount: NSDecimalNumber(decimal: money.amount).doubleValue
            )
        }
        .sorted { $0.amount > $1.amount }
        .prefix(8)
        .map { $0 }
    }

    private var cashFlowPoints: [CashFlowPoint] {
        guard let currency = model.profile?.baseCurrency else { return [] }
        let calendar = Calendar.current
        let incomeLabel = String(localized: "transaction.income")
        let expenseLabel = String(localized: "transaction.expense")
        var points: [CashFlowPoint] = []

        for offset in -5...0 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: Date()),
                  let interval = calendar.dateInterval(of: .month, for: month) else { continue }
            let income = (try? FinanceCalculator.total(
                for: .income,
                accounts: model.accounts,
                entries: model.entries,
                currency: currency,
                interval: interval
            )) ?? Money.zero(currency: currency)
            let expense = (try? FinanceCalculator.total(
                for: .expense,
                accounts: model.accounts,
                entries: model.entries,
                currency: currency,
                interval: interval
            )) ?? Money.zero(currency: currency)
            points.append(
                CashFlowPoint(
                    month: interval.start,
                    series: incomeLabel,
                    amount: NSDecimalNumber(decimal: income.amount).doubleValue
                )
            )
            points.append(
                CashFlowPoint(
                    month: interval.start,
                    series: expenseLabel,
                    amount: NSDecimalNumber(decimal: expense.amount).doubleValue
                )
            )
        }
        return points
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let totals = currentTotals {
                        HStack(spacing: 10) {
                            MetricCard(
                                title: "transaction.income",
                                value: formattedMoney(totals.income),
                                color: .green
                            )
                            MetricCard(
                                title: "transaction.expense",
                                value: formattedMoney(totals.expense),
                                color: .orange
                            )
                            MetricCard(
                                title: "insights.net",
                                value: formattedMoney(totals.net),
                                color: totals.net.amount >= .zero ? .blue : .red
                            )
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("insights.category_spending")
                                .font(.headline)
                            if categoryPoints.isEmpty {
                                Text("insights.no_spending")
                                    .foregroundStyle(.secondary)
                            } else {
                                Chart(categoryPoints) { point in
                                    BarMark(
                                        x: .value("Amount", point.amount),
                                        y: .value("Category", point.name)
                                    )
                                    .foregroundStyle(Color.accentColor)
                                    .annotation(position: .trailing) {
                                        Text(point.amount, format: .number.precision(.fractionLength(0...2)))
                                            .font(.caption2)
                                    }
                                }
                                .frame(height: max(190, CGFloat(categoryPoints.count) * 34))
                                .chartXAxis(.hidden)
                            }
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("insights.six_month_flow")
                                .font(.headline)
                            Chart(cashFlowPoints) { point in
                                BarMark(
                                    x: .value("Month", point.month, unit: .month),
                                    y: .value("Amount", point.amount)
                                )
                                .foregroundStyle(by: .value("Flow", point.series))
                                .position(by: .value("Flow", point.series))
                            }
                            .frame(height: 240)
                            .chartForegroundStyleScale([
                                String(localized: "transaction.income"): Color.green,
                                String(localized: "transaction.expense"): Color.orange
                            ])
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("insights.reading")
                                .font(.headline)
                            Text(insightSummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("tab.insights")
        }
    }

    private var insightSummary: LocalizedStringKey {
        guard let totals = currentTotals else { return "insights.no_data" }
        if totals.expense.amount > totals.income.amount {
            return "insights.spending_above_income"
        }
        if totals.expense.amount == .zero {
            return "insights.no_expense_yet"
        }
        return "insights.positive_flow"
    }
}

private struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
