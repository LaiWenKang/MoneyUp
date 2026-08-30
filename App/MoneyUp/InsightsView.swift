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
    enum FlowSeriesKind: String {
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

    struct FlowPoint: Identifiable {
        let month: Date
        let kind: FlowSeriesKind
        let money: Money

        var id: String { "\(kind.rawValue)@\(month.timeIntervalSinceReferenceDate)" }
        var series: String { kind.title }
        var amount: Double { NSDecimalNumber(decimal: money.amount).doubleValue }
    }

    static let visibleCategoryCount = 8

    @Environment(AppModel.self) var model
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @State var period: ReportPeriod = .thisMonth
    @State var selectedCategoryKey: String?
    @State var selectedFlowMonth: Date?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MoneyUpLayout.standardSpacing) {
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
                    MoneyUpCard {
                        DerivedValueUnavailableView(
                            issue: issue,
                            prominent: true
                        )
                    }
                }
            }
            .padding()
            .frame(maxWidth: MoneyUpLayout.readableContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background { MoneyUpBackdrop() }
        .navigationTitle("tab.insights")
        .onChange(of: period) { _, _ in
            selectedCategoryKey = nil
            selectedFlowMonth = nil
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    var periodCard: some View {
        MoneyUpCard {
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

    func totalsRow(_ report: PeriodReport) -> some View {
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
    func totalsCards(_ report: PeriodReport) -> some View {
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

    func foreignCurrencyCard(_ report: PeriodReport) -> some View {
        MoneyUpCard {
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

    func categoryCard(_ report: PeriodReport) -> some View {
        let pointsResult = categoryPointsResult(report)

        return MoneyUpCard {
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
                            x: .value(
                                String(localized: "chart.dimension.amount"),
                                point.amount
                            ),
                            y: .value(
                                String(localized: "chart.dimension.category"),
                                point.selectionKey
                            )
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
