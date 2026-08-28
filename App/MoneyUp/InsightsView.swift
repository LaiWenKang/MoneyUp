import Charts
import MoneyUpCore
import SwiftUI

struct InsightsCategoryPoint: Identifiable, Equatable {
    let selectionKey: String
    let name: String
    let money: Money
    /// Every category whose postings contribute to this exact chart bar.
    let categoryIDs: Set<UUID>
    let isAggregate: Bool

    var id: String { selectionKey }
    var amount: Double { NSDecimalNumber(decimal: money.amount).doubleValue }
}

enum InsightsCategoryBucketBuilder {
    static let aggregateSelectionKey = "insights-category:aggregate:other"

    static func points(
        from spending: [CategorySpending],
        visibleCategoryCount: Int,
        baseCurrency: CurrencyCode,
        otherName: String
    ) throws -> [InsightsCategoryPoint] {
        let positiveSpending = spending.filter { $0.amount.amount > .zero }
        let visibleCount = max(0, visibleCategoryCount)
        var points = positiveSpending.prefix(visibleCount).map { category in
            InsightsCategoryPoint(
                selectionKey: selectionKey(for: category.accountID),
                name: category.name,
                money: category.amount,
                categoryIDs: [category.accountID],
                isAggregate: false
            )
        }

        let remainder = positiveSpending.dropFirst(visibleCount)
        guard !remainder.isEmpty else { return points }

        var aggregateAmount = Decimal.zero
        var aggregateCategoryIDs = Set<UUID>()
        aggregateCategoryIDs.reserveCapacity(remainder.count)
        for category in remainder {
            aggregateAmount = try CheckedDecimal.adding(
                aggregateAmount,
                category.amount.amount
            )
            aggregateCategoryIDs.insert(category.accountID)
        }
        points.append(
            InsightsCategoryPoint(
                selectionKey: aggregateSelectionKey,
                name: otherName,
                money: try Money(aggregateAmount, currency: baseCurrency),
                categoryIDs: aggregateCategoryIDs,
                isAggregate: true
            )
        )
        return points
    }

    static func selectionKey(for categoryID: UUID) -> String {
        "insights-category:id:\(categoryID.uuidString.lowercased())"
    }
}

struct InsightsView: View {
    private enum FlowSeriesKind: String {
        case income
        case expense

        var title: String {
            switch self {
            case .income: String(localized: "transaction.income")
            case .expense: String(localized: "transaction.expense")
            }
        }

        var symbol: String {
            switch self {
            case .income: "plus.rectangle.fill"
            case .expense: "minus.rectangle"
            }
        }
    }

    private struct FlowPoint: Identifiable {
        let month: Date
        let kind: FlowSeriesKind
        let money: Money

        var id: String { "\(kind.rawValue)@\(month.timeIntervalSinceReferenceDate)" }
        var series: String { kind.title }
        var amount: Double { NSDecimalNumber(decimal: money.amount).doubleValue }
    }

    private static let visibleCategoryCount = 8

    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: ReportPeriod = .thisMonth
    @State private var selectedCategoryKey: String?
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
                selectedCategoryKey = nil
                selectedFlowMonth = nil
            }
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
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
                            y: .value("Category ID", point.selectionKey)
                        )
                        .foregroundStyle(
                            point.isAggregate
                                ? Color.secondary
                                : Color.accentColor
                        )
                        .opacity(
                            selectedCategoryKey == nil
                                || selectedCategoryKey == point.selectionKey ? 1 : 0.34
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
                    .chartYScale(domain: points.map(\.selectionKey))
                    .chartYAxis {
                        AxisMarks(values: points.map(\.selectionKey)) { value in
                            AxisValueLabel {
                                if let key = value.as(String.self),
                                   let point = points.first(where: {
                                       $0.selectionKey == key
                                   }) {
                                    Text(point.name)
                                }
                            }
                        }
                    }
                    .chartYSelection(value: $selectedCategoryKey)
                    .frame(height: max(190, CGFloat(points.count) * 34))
                    .accessibilityLabel(Text("insights.category_chart"))
                    .accessibilityValue(Text(categoryChartSummary(points)))
                    .accessibilityHint(Text("insights.chart_accessibility_hint"))

                    Text("insights.tap_chart")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let selected = points.first(where: {
                        $0.selectionKey == selectedCategoryKey
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

                Label(
                    analysisWindowDescription(report),
                    systemImage: "selection.pin.in.out"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                if hasActivity {
                    Chart {
                        RuleMark(
                            x: .value("Selected period start", report.interval.start)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color.primary.opacity(0.45))

                        RuleMark(
                            x: .value(
                                "Selected period end",
                                report.interval.end.addingTimeInterval(-1)
                            )
                        )
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color.primary.opacity(0.45))

                        ForEach(points) { point in
                            BarMark(
                                x: .value("Month", point.month, unit: .month),
                                y: .value("Amount", point.amount)
                            )
                            .foregroundStyle(by: .value("Flow", point.series))
                            .position(by: .value("Flow", point.series))
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
                        String(localized: "transaction.income"): Color.green,
                        String(localized: "transaction.expense"): Color.accentColor
                    ])
                    .chartLegend(.hidden)
                    .chartXSelection(value: $selectedFlowMonth)
                    .accessibilityLabel(Text("insights.flow_chart"))
                    .accessibilityValue(Text(flowChartSummary(report)))
                    .accessibilityHint(Text("insights.chart_accessibility_hint"))

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

    private func flowAccessibilityLabel(_ point: FlowPoint) -> String {
        let month = point.month.formattedForReporting(
            .dateTime.month(.wide).year(),
            calendar: model.reportingCalendar
        )
        return "\(month), \(point.series)"
    }

    private func selectedCategoryCard(
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

    private func selectedFlowCard(_ flow: MonthlyFlow) -> some View {
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
    ) -> DerivedValue<[InsightsCategoryPoint]> {
        do {
            return .available(
                try InsightsCategoryBucketBuilder.points(
                    from: report.categorySpending,
                    visibleCategoryCount: Self.visibleCategoryCount,
                    baseCurrency: report.baseCurrency,
                    otherName: String(localized: "insights.other_category")
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

    private func flowPoints(_ report: PeriodReport) -> [FlowPoint] {
        return report.monthlyFlows.flatMap { flow in
            [
                FlowPoint(month: flow.month, kind: .income, money: flow.income),
                FlowPoint(month: flow.month, kind: .expense, money: flow.expense)
            ]
        }
    }

    private func flowLegend(
        _ kind: FlowSeriesKind,
        color: Color
    ) -> some View {
        Label(kind.title, systemImage: kind.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
    }

    private func analysisWindowDescription(_ report: PeriodReport) -> String {
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
            format: String(localized: "insights.selected_window_format"),
            start,
            inclusiveEnd
        )
    }

    private func categoryChartSummary(_ points: [InsightsCategoryPoint]) -> String {
        guard let largest = points.first else {
            return String(localized: "insights.no_spending")
        }
        return String(
            format: String(localized: "insights.category_chart_summary_format"),
            points.count,
            largest.name,
            formattedMoney(largest.money)
        )
    }

    private func flowChartSummary(_ report: PeriodReport) -> String {
        guard let latest = report.monthlyFlows.last else {
            return analysisWindowDescription(report)
        }
        return String(
            format: String(localized: "insights.flow_chart_summary_format"),
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

        do {
            if let rate = try report.savingsRate() {
                if rate >= .zero {
                    lines.append(
                        String(
                            format: String(localized: "insights.savings_rate_format"),
                            formattedPercent(rate)
                        )
                    )
                } else {
                    let gap = try report.baseFlow.expense
                        .subtracting(report.baseFlow.income)
                    lines.append(
                        String(
                            format: String(localized: "insights.overspend_format"),
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

        do {
            if let largest = try report.largestCategory() {
                lines.append(
                    String(
                        format: String(localized: "insights.largest_category_format"),
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
            lines.isEmpty ? [String(localized: "insights.no_data")] : lines,
            issue
        )
    }

    private func monthToDateComparisonLine(
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
