import Charts
import MoneyUpCore
import SwiftUI

extension InsightsView {
    func cashFlowCard(_ report: PeriodReport) -> some View {
        let points = flowPoints(report)
        let hasActivity = points.contains { $0.money.amount != .zero }

        return MoneyUpCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("insights.monthly_flow")
                    .font(.headline)

                Label(
                    analysisWindowDescription(report),
                    systemImage: "selection.pin.in.out"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                if hasActivity {
                    cashFlowChart(report, points: points)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            flowLegend(.income, color: .green)
                            flowLegend(.expense, color: .accentColor)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            flowLegend(.income, color: .green)
                            flowLegend(.expense, color: .accentColor)
                        }
                    }

                    Text("insights.tap_chart")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let selectedFlow = report.monthlyFlows.first(where: {
                        guard let selectedFlowMonth else { return false }
                        return model.reportingCalendar.isDate(
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

    private func cashFlowChart(
        _ report: PeriodReport,
        points: [FlowPoint]
    ) -> some View {
        Chart {
            RuleMark(
                x: .value(
                    AppLocalization.string("chart.dimension.selected_period_start"),
                    report.interval.start
                )
            )
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(Color.primary.opacity(0.45))

            RuleMark(
                x: .value(
                    AppLocalization.string("chart.dimension.selected_period_end"),
                    report.interval.end.addingTimeInterval(-1)
                )
            )
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(Color.primary.opacity(0.45))

            ForEach(points) { point in
                BarMark(
                    x: .value(
                        AppLocalization.string("chart.dimension.month"),
                        point.month,
                        unit: .month
                    ),
                    y: .value(
                        AppLocalization.string("chart.dimension.amount"),
                        point.amount
                    )
                )
                .foregroundStyle(
                    by: .value(
                        AppLocalization.string("chart.dimension.flow"),
                        point.series
                    )
                )
                .position(
                    by: .value(
                        AppLocalization.string("chart.dimension.flow"),
                        point.series
                    )
                )
                .cornerRadius(point.kind == .income ? 5 : 0)
                .opacity(
                    selectedFlowMonth == nil
                        || model.reportingCalendar.isDate(
                            point.month,
                            equalTo: selectedFlowMonth ?? point.month,
                            toGranularity: .month
                        ) ? 1 : 0.34
                )
                .accessibilityLabel(flowAccessibilityLabel(point))
                .accessibilityValue(formattedMoney(point.money))
            }
        }
        .frame(height: 240)
        .chartForegroundStyleScale([
            AppLocalization.string("transaction.income"): Color.green,
            AppLocalization.string("transaction.expense"): Color.accentColor
        ])
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedFlowMonth)
        .accessibilityLabel(Text("insights.flow_chart"))
        .accessibilityValue(Text(flowChartSummary(report)))
        .accessibilityHint(Text("insights.chart_accessibility_hint"))
    }

    func flowAccessibilityLabel(_ point: FlowPoint) -> String {
        let month = point.month.formattedForReporting(
            .dateTime.month(.wide).year(),
            calendar: model.reportingCalendar
        )
        return "\(month), \(point.series)"
    }

    func selectedCategoryCard(
        _ point: InsightsCategoryPoint,
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
                            categoryIDs: point.categoryIDs,
                            categoryPostingCurrency: report.baseCurrency,
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

    func selectedFlowCard(_ flow: MonthlyFlow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(flow.month.formattedForReporting(
                .dateTime.month(.wide).year(),
                calendar: model.reportingCalendar
            ))
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

            if let interval = model.reportingCalendar.dateInterval(
                of: .month,
                for: flow.month
            ) {
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

    func flowValue(
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

    func insightCard(_ report: PeriodReport) -> some View {
        let reading = insightReading(report)

        return MoneyUpCard {
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

    func categoryPointsResult(
        _ report: PeriodReport
    ) -> DerivedValue<[InsightsCategoryPoint]> {
        do {
            return .available(
                try InsightsCategoryBucketBuilder.points(
                    from: report.categorySpending,
                    visibleCategoryCount: Self.visibleCategoryCount,
                    baseCurrency: report.baseCurrency,
                    otherName: AppLocalization.string("insights.other_category")
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "insights-other-category",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    func flowPoints(_ report: PeriodReport) -> [FlowPoint] {
        return report.monthlyFlows.flatMap { flow in
            [
                FlowPoint(month: flow.month, kind: .income, money: flow.income),
                FlowPoint(month: flow.month, kind: .expense, money: flow.expense)
            ]
        }
    }

    func flowLegend(
        _ kind: FlowSeriesKind,
        color: Color
    ) -> some View {
        Label(kind.title, systemImage: kind.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
    }

    func analysisWindowDescription(_ report: PeriodReport) -> String {
        let start = report.interval.start.formattedForReporting(
            .dateTime.month(.abbreviated).year(),
            calendar: model.reportingCalendar
        )
        let inclusiveEnd = report.interval.end.addingTimeInterval(-1)
            .formattedForReporting(
                .dateTime.month(.abbreviated).year(),
                calendar: model.reportingCalendar
            )
        return String(
            format: AppLocalization.string("insights.selected_window_format"),
            start,
            inclusiveEnd
        )
    }

    func categoryChartSummary(_ points: [InsightsCategoryPoint]) -> String {
        guard let largest = points.first else {
            return AppLocalization.string("insights.no_spending")
        }
        return String(
            format: AppLocalization.string("insights.category_chart_summary_format"),
            points.count,
            largest.name,
            formattedMoney(largest.money)
        )
    }

    func flowChartSummary(_ report: PeriodReport) -> String {
        guard let latest = report.monthlyFlows.last else {
            return analysisWindowDescription(report)
        }
        return String(
            format: AppLocalization.string("insights.flow_chart_summary_format"),
            report.monthlyFlows.count,
            analysisWindowDescription(report),
            latest.month.formattedForReporting(
                .dateTime.month(.wide).year(),
                calendar: model.reportingCalendar
            ),
            formattedMoney(latest.income),
            formattedMoney(latest.expense)
        )
    }

    /// Deterministic, on-device readings. Every line is arithmetic over the
    /// selected period, so it can be checked against the charts above it.
    func insightReading(
        _ report: PeriodReport
    ) -> (lines: [String], issue: DerivedValueIssue?) {
        guard !report.isEmpty else {
            return ([AppLocalization.string("insights.no_data")], nil)
        }
        var lines: [String] = []
        var issue: DerivedValueIssue?

        // Suppressed when foreign spending exists: the card above already
        // shows it, and calling the period empty would read as wrong.
        if report.baseFlow.expense.amount <= .zero, !report.holdsUnconvertedActivity {
            lines.append(AppLocalization.string("insights.no_expense_yet"))
        }

        appendSavingsReading(report, to: &lines, issue: &issue)

        do {
            if let largest = try report.largestCategory() {
                lines.append(
                    String(
                        format: AppLocalization.string("insights.largest_category_format"),
                        largest.category.name,
                        formattedPercent(largest.share)
                    )
                )
            }
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "insights-category-share",
                error: error
            )
            issue = .amountCalculationFailed
        }

        if period == .thisMonth {
            if case let .available(comparison) =
                model.monthToDateExpenseComparisonResult(),
               !comparison.holdsUnconvertedActivity {
                do {
                    lines.append(contentsOf: try monthToDateComparisonLine(
                        previous: comparison.previous.amount,
                        latest: comparison.current.amount
                    ))
                } catch {
                    DerivedValueDiagnostics.record(
                        .amountCalculationFailed,
                        operation: "insights-month-comparison",
                        error: error
                    )
                    issue = .amountCalculationFailed
                }
            }
        }

        return (
            lines.isEmpty ? [AppLocalization.string("insights.no_data")] : lines,
            issue
        )
    }

    private func appendSavingsReading(
        _ report: PeriodReport,
        to lines: inout [String],
        issue: inout DerivedValueIssue?
    ) {
        do {
            if let rate = try report.savingsRate() {
                if rate >= .zero {
                    lines.append(
                        String(
                            format: AppLocalization.string("insights.savings_rate_format"),
                            formattedPercent(rate)
                        )
                    )
                } else {
                    let gap = try report.baseFlow.expense
                        .subtracting(report.baseFlow.income)
                    lines.append(
                        String(
                            format: AppLocalization.string("insights.overspend_format"),
                            formattedMoney(gap)
                        )
                    )
                }
            }
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "insights-savings-reading",
                error: error
            )
            issue = .amountCalculationFailed
        }
    }

    func monthToDateComparisonLine(
        previous: Decimal,
        latest: Decimal
    ) throws -> [String] {
        guard previous > .zero else { return [] }

        let difference = try CheckedDecimal.subtracting(latest, previous)
        let delta = try CheckedDecimal.ratio(difference, previous)
        let threshold = Decimal(string: "0.005")!

        if delta > threshold {
            return [
                String(
                    format: AppLocalization.string("insights.spending_up_format"),
                    formattedPercent(delta)
                )
            ]
        }
        if delta < -threshold {
            return [
                String(
                    format: AppLocalization.string("insights.spending_down_format"),
                    formattedPercent(-delta)
                )
            ]
        }
        return [AppLocalization.string("insights.spending_flat")]
    }
}
