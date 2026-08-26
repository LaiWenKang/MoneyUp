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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: ReportPeriod = .thisMonth
    @State private var selectedCategoryName: String?
    @State private var selectedFlowMonth: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    periodCard

                    switch model.reportResult(for: period) {
                    case let .available(report):
                        totalsRow(report)
                        if report.holdsUnconvertedActivity {
                            foreignCurrencyCard(report)
                        }
                        categoryCard(report)
                        cashFlowCard(report)
                        insightCard(report)
                    case let .unavailable(issue):
                        DashboardCard {
                            DerivedValueUnavailableView(
                                issue: issue,
                                prominent: true
                            )
                        }
                    }
                }
                .padding()
            }
            .background { MoneyUpBackdrop() }
            .navigationTitle("tab.insights")
            .onChange(of: period) { _, _ in
                selectedCategoryName = nil
                selectedFlowMonth = nil
            }
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    totalsCards(report)
                }
            } else {
                HStack(spacing: 10) {
                    totalsCards(report)
                }
            }
        }
    }

    @ViewBuilder
    private func totalsCards(_ report: PeriodReport) -> some View {
        MetricCard(
            title: "transaction.income",
            value: formattedMoney(report.baseFlow.income),
            color: .green
        )
        MetricCard(
            title: "transaction.expense",
            value: formattedMoney(report.baseFlow.expense),
            color: .accentColor
        )
        MetricCard(
            title: "insights.net",
            value: formattedMoney(report.baseFlow.net),
            color: report.baseFlow.net.amount >= .zero ? .accentColor : .red
        )
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
        let pointsResult = categoryPointsResult(report)

        return DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("insights.category_spending")
                    .font(.headline)

                if case let .available(points) = pointsResult,
                   points.isEmpty {
                    Text("insights.no_spending")
                        .foregroundStyle(.secondary)
                } else if case let .available(points) = pointsResult {
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
                        .opacity(
                            selectedCategoryName == nil
                                || selectedCategoryName == point.name ? 1 : 0.34
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
                    .chartYSelection(value: $selectedCategoryName)
                    .frame(height: max(190, CGFloat(points.count) * 34))
                    .accessibilityLabel(Text("insights.category_chart"))

                    Text("insights.tap_chart")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let selected = points.first(where: {
                        $0.name == selectedCategoryName
                    }) {
                        selectedCategoryCard(selected, report: report)
                    }
                } else if case let .unavailable(issue) = pointsResult {
                    DerivedValueUnavailableView(issue: issue)
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
                        .opacity(
                            selectedFlowMonth == nil
                                || Calendar.current.isDate(
                                    point.month,
                                    equalTo: selectedFlowMonth ?? point.month,
                                    toGranularity: .month
                                ) ? 1 : 0.34
                        )
                        .accessibilityLabel(point.series)
                        .accessibilityValue(formattedMoney(point.money))
                    }
                    .frame(height: 240)
                    .chartForegroundStyleScale([
                        String(localized: "transaction.income"): Color.green,
                        String(localized: "transaction.expense"): Color.accentColor
                    ])
                    .chartXSelection(value: $selectedFlowMonth)
                    .accessibilityLabel(Text("insights.flow_chart"))

                    Text("insights.tap_chart")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let selectedFlow = report.monthlyFlows.first(where: {
                        guard let selectedFlowMonth else { return false }
                        return Calendar.current.isDate(
                            $0.month,
                            equalTo: selectedFlowMonth,
                            toGranularity: .month
                        )
                    }) {
                        selectedFlowCard(selectedFlow)
                    }
                } else {
                    Text("insights.no_flow_data")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectedCategoryCard(
        _ point: CategoryPoint,
        report: PeriodReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.name)
                        .font(.subheadline.weight(.semibold))
                    Text(formattedMoney(point.money))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                NavigationLink {
                    HistoryView(
                        preset: HistoryPreset(
                            categoryID: point.id == Self.otherCategoryID ? nil : point.id,
                            interval: report.interval
                        )
                    )
                } label: {
                    Label("insights.view_transactions", systemImage: "arrow.right.circle.fill")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func selectedFlowCard(_ flow: MonthlyFlow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(flow.month, format: .dateTime.month(.wide).year())
                .font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    flowValue("transaction.income", money: flow.income)
                    flowValue("transaction.expense", money: flow.expense)
                    flowValue("insights.net", money: flow.net)
                }
                VStack(alignment: .leading, spacing: 8) {
                    flowValue("transaction.income", money: flow.income)
                    flowValue("transaction.expense", money: flow.expense)
                    flowValue("insights.net", money: flow.net)
                }
            }

            if let interval = Calendar.current.dateInterval(of: .month, for: flow.month) {
                NavigationLink {
                    HistoryView(preset: HistoryPreset(interval: interval))
                } label: {
                    Label("insights.view_transactions", systemImage: "arrow.right.circle.fill")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func flowValue(
        _ title: LocalizedStringKey,
        money: Money
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedMoney(money))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func insightCard(_ report: PeriodReport) -> some View {
        let reading = insightReading(report)

        return DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("insights.reading")
                    .font(.headline)

                ForEach(reading.lines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let issue = reading.issue {
                    DerivedValueUnavailableView(issue: issue)
                }

                if period == .thisMonth,
                   case let .unavailable(issue) =
                       model.monthToDateExpenseComparisonResult() {
                    DerivedValueUnavailableView(issue: issue)
                }
            }
        }
    }

    private func categoryPointsResult(
        _ report: PeriodReport
    ) -> DerivedValue<[CategoryPoint]> {
        let spending = report.categorySpending.filter { $0.amount.amount > .zero }
        var points = spending.prefix(Self.visibleCategoryCount).map {
            CategoryPoint(id: $0.accountID, name: $0.name, money: $0.amount)
        }

        let remainder = spending.dropFirst(Self.visibleCategoryCount)
        if !remainder.isEmpty {
            let total = remainder.reduce(Decimal.zero) { $0 + $1.amount.amount }
            switch DerivedValue<Money>.money(
                total,
                currency: report.baseCurrency,
                operation: "insights-other-category"
            ) {
            case let .available(money):
                points.append(
                    CategoryPoint(
                        id: Self.otherCategoryID,
                        name: String(localized: "insights.other_category"),
                        money: money
                    )
                )
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }
        return .available(points)
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
    private func insightReading(
        _ report: PeriodReport
    ) -> (lines: [String], issue: DerivedValueIssue?) {
        guard !report.isEmpty else {
            return ([String(localized: "insights.no_data")], nil)
        }
        var lines: [String] = []
        var issue: DerivedValueIssue?

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
            } else {
                do {
                    let gap = try report.baseFlow.expense
                        .subtracting(report.baseFlow.income)
                    lines.append(
                        String(
                            format: String(localized: "insights.overspend_format"),
                            formattedMoney(gap)
                        )
                    )
                } catch {
                    DerivedValueDiagnostics.record(
                        .amountCalculationFailed,
                        operation: "insights-overspend-gap",
                        error: error
                    )
                    issue = .amountCalculationFailed
                }
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

        if period == .thisMonth {
            if case let .available(comparison) =
                model.monthToDateExpenseComparisonResult(),
               !comparison.holdsUnconvertedActivity {
                lines.append(
                    contentsOf: monthToDateComparisonLine(
                        previous: comparison.previous.amount,
                        latest: comparison.current.amount
                    )
                )
            }
        }

        return (
            lines.isEmpty ? [String(localized: "insights.no_data")] : lines,
            issue
        )
    }

    private func monthToDateComparisonLine(
        previous: Decimal,
        latest: Decimal
    ) -> [String] {
        guard previous > .zero else { return [] }

        let delta = (latest - previous) / previous
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
                .minimumScaleFactor(0.80)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
