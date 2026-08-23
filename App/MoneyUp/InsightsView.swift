import Charts
import MoneyUpCore
import SwiftUI

struct InsightsView: View {
    private struct CategoryPoint: Identifiable {
        let id: UUID
        let name: String
        let money: Money

        var amount: Double { NSDecimalNumber(decimal: money.amount).doubleValue }
    }

    private struct FlowPoint: Identifiable {
        let month: Date
        let series: String
        let money: Money

        var id: String { "\(series)@\(month.timeIntervalSinceReferenceDate)" }
        var amount: Double { NSDecimalNumber(decimal: money.amount).doubleValue }
    }

    /// Stable identity for the bucket that holds every category beyond the
    /// ones drawn individually, so the bars still add up to the total.
    private static let otherCategoryID = UUID()
    private static let visibleCategoryCount = 8

    @EnvironmentObject private var model: AppModel
    @State private var period: ReportPeriod = .thisMonth

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    periodCard

                    if let report = model.report(for: period) {
                        totalsRow(report)
                        if report.holdsUnconvertedActivity {
                            foreignCurrencyCard(report)
                        }
                        categoryCard(report)
                        cashFlowCard(report)
                        insightCard(report)
                    } else {
                        DashboardCard {
                            Text("insights.no_data")
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

    private var periodCard: some View {
        DashboardCard {
            HStack {
                Text("insights.period")
                    .font(.headline)
                Spacer(minLength: 12)
                Picker("insights.period", selection: $period) {
                    ForEach(ReportPeriod.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func totalsRow(_ report: PeriodReport) -> some View {
        HStack(spacing: 10) {
            MetricCard(
                title: "transaction.income",
                value: formattedMoney(report.baseFlow.income),
                color: .green
            )
            MetricCard(
                title: "transaction.expense",
                value: formattedMoney(report.baseFlow.expense),
                color: .orange
            )
            MetricCard(
                title: "insights.net",
                value: formattedMoney(report.baseFlow.net),
                color: report.baseFlow.net.amount >= .zero ? .blue : .red
            )
        }
    }

    private func foreignCurrencyCard(_ report: PeriodReport) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("insights.other_currencies", systemImage: "arrow.left.arrow.right")
                    .font(.headline)

                ForEach(report.foreignFlows) { flow in
                    HStack {
                        Text(flow.currency.value)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 12)
                        Text(formattedMoney(flow.net))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(flow.net.amount >= .zero ? Color.primary : Color.red)
                    }
                    .accessibilityElement(children: .combine)
                }

                Text("insights.other_currencies_detail")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryCard(_ report: PeriodReport) -> some View {
        let points = categoryPoints(report)

        return DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("insights.category_spending")
                    .font(.headline)

                if points.isEmpty {
                    Text("insights.no_spending")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(points) { point in
                        BarMark(
                            x: .value("Amount", point.amount),
                            y: .value("Category", point.name)
                        )
                        .foregroundStyle(
                            point.id == Self.otherCategoryID
                                ? Color.secondary
                                : Color.accentColor
                        )
                        .annotation(position: .trailing) {
                            Text(formattedMoney(point.money))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(point.name)
                        .accessibilityValue(formattedMoney(point.money))
                    }
                    .chartXAxis(.hidden)
                    .frame(height: max(190, CGFloat(points.count) * 34))
                    .accessibilityLabel(Text("insights.category_chart"))
                }
            }
        }
    }

    private func cashFlowCard(_ report: PeriodReport) -> some View {
        let points = flowPoints(report)
        let hasActivity = points.contains { $0.money.amount != .zero }

        return DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("insights.monthly_flow")
                    .font(.headline)

                if hasActivity {
                    Chart(points) { point in
                        BarMark(
                            x: .value("Month", point.month, unit: .month),
                            y: .value("Amount", point.amount)
                        )
                        .foregroundStyle(by: .value("Flow", point.series))
                        .position(by: .value("Flow", point.series))
                        .accessibilityLabel(point.series)
                        .accessibilityValue(formattedMoney(point.money))
                    }
                    .frame(height: 240)
                    .chartForegroundStyleScale([
                        String(localized: "transaction.income"): Color.green,
                        String(localized: "transaction.expense"): Color.orange
                    ])
                    .accessibilityLabel(Text("insights.flow_chart"))
                } else {
                    Text("insights.no_flow_data")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func insightCard(_ report: PeriodReport) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("insights.reading")
                    .font(.headline)

                ForEach(insightLines(report), id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func categoryPoints(_ report: PeriodReport) -> [CategoryPoint] {
        let spending = report.categorySpending.filter { $0.amount.amount > .zero }
        var points = spending.prefix(Self.visibleCategoryCount).map {
            CategoryPoint(id: $0.accountID, name: $0.name, money: $0.amount)
        }

        let remainder = spending.dropFirst(Self.visibleCategoryCount)
        if !remainder.isEmpty {
            let total = remainder.reduce(Decimal.zero) { $0 + $1.amount.amount }
            if let money = try? Money(total, currency: report.baseCurrency) {
                points.append(
                    CategoryPoint(
                        id: Self.otherCategoryID,
                        name: String(localized: "insights.other_category"),
                        money: money
                    )
                )
            }
        }
        return points
    }

    private func flowPoints(_ report: PeriodReport) -> [FlowPoint] {
        let incomeLabel = String(localized: "transaction.income")
        let expenseLabel = String(localized: "transaction.expense")

        return report.monthlyFlows.flatMap { flow in
            [
                FlowPoint(month: flow.month, series: incomeLabel, money: flow.income),
                FlowPoint(month: flow.month, series: expenseLabel, money: flow.expense)
            ]
        }
    }

    /// Deterministic, on-device readings. Every line is arithmetic over the
    /// selected period, so it can be checked against the charts above it.
    private func insightLines(_ report: PeriodReport) -> [String] {
        guard !report.isEmpty else { return [String(localized: "insights.no_data")] }
        var lines: [String] = []

        // Suppressed when foreign spending exists: the card above already
        // shows it, and calling the period empty would read as wrong.
        if report.baseFlow.expense.amount <= .zero, !report.holdsUnconvertedActivity {
            lines.append(String(localized: "insights.no_expense_yet"))
        }

        if let rate = report.savingsRate {
            if rate >= .zero {
                lines.append(
                    String(
                        format: String(localized: "insights.savings_rate_format"),
                        formattedPercent(rate)
                    )
                )
            } else if let gap = try? report.baseFlow.expense
                .subtracting(report.baseFlow.income) {
                lines.append(
                    String(
                        format: String(localized: "insights.overspend_format"),
                        formattedMoney(gap)
                    )
                )
            }
        }

        if let largest = report.largestCategory {
            lines.append(
                String(
                    format: String(localized: "insights.largest_category_format"),
                    largest.category.name,
                    formattedPercent(largest.share)
                )
            )
        }

        if period == .thisMonth, let change = report.monthOverMonth {
            lines.append(contentsOf: monthOverMonthLine(change))
        }

        return lines.isEmpty ? [String(localized: "insights.no_data")] : lines
    }

    private func monthOverMonthLine(
        _ change: (previous: MonthlyFlow, latest: MonthlyFlow)
    ) -> [String] {
        let previous = change.previous.expense.amount
        guard previous > .zero else { return [] }

        let delta = (change.latest.expense.amount - previous) / previous
        let threshold = Decimal(1) / Decimal(200)

        if delta > threshold {
            return [
                String(
                    format: String(localized: "insights.spending_up_format"),
                    formattedPercent(delta)
                )
            ]
        }
        if delta < -threshold {
            return [
                String(
                    format: String(localized: "insights.spending_down_format"),
                    formattedPercent(-delta)
                )
            ]
        }
        return [String(localized: "insights.spending_flat")]
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
        .accessibilityElement(children: .combine)
    }
}
