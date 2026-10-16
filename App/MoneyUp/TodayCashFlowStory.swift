import Charts
import MoneyUpCore
import SwiftUI

/// A partial month is labelled as such; this never compares it with a complete
/// month or combines unconverted currencies into a claimed spending trend.
struct TodayCashFlowStory: View {
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    let report: PeriodReport
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(maskingAmounts: displayedAmount(report.baseFlow.net))
                // Code and figure stay together; a long figure shrinks. Set
                // inside the typography modifier, which otherwise wins.
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .moneyUpFinancialValue(.prominent)
            Text("dashboard.flow.net_to_date")
                .font(.caption).foregroundStyle(.moneyUpSecondary)
            if Self.usesMonthlyFlowDetails(dynamicTypeSize: dynamicTypeSize, voiceOverEnabled: voiceOverEnabled) {
                monthlyFlowDetails
            } else {
                Chart(Array(report.monthlyFlows.suffix(6)), id: \.month) { flow in
                    BarMark(
                        x: .value(AppLocalization.string("chart.dimension.month"), flow.month, unit: .month, calendar: calendar),
                        y: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: flow.income.amount).doubleValue)
                    )
                    .foregroundStyle(by: .value(AppLocalization.string("history.income"), AppLocalization.string("history.income")))
                    .position(by: .value(AppLocalization.string("chart.dimension.kind"), AppLocalization.string("history.income")))
                    BarMark(
                        x: .value(AppLocalization.string("chart.dimension.month"), flow.month, unit: .month, calendar: calendar),
                        y: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: flow.expense.amount).doubleValue)
                    )
                    .foregroundStyle(by: .value(AppLocalization.string("history.spent"), AppLocalization.string("history.spent")))
                    .position(by: .value(AppLocalization.string("chart.dimension.kind"), AppLocalization.string("history.spent")))
                }
                .chartForegroundStyleScale([
                    AppLocalization.string("history.income"): Color.moneyUpChartSeries1,
                    AppLocalization.string("history.spent"): Color.moneyUpChartSeries2
                ])
                .chartXScale(range: .plotDimension(padding: 16))
                .chartXAxis {
                    AxisMarks(values: report.monthlyFlows.suffix(6).map { $0.month.reportingMonthMidpoint(calendar: calendar) }) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date.formattedForReporting(.dateTime.month(.abbreviated), calendar: calendar))
                                    .fixedSize()
                            }
                        }
                    }
                }
                .chartYAxis(hidesAmounts ? .hidden : .automatic)
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 130)
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                .accessibilityHidden(true)
            }
            flowRow("history.income", report.baseFlow.income)
            flowRow("history.spent", report.baseFlow.expense)
            if !report.foreignFlows.isEmpty {
                Text("dashboard.flow.other_currencies").font(.caption).foregroundStyle(.moneyUpSecondary)
            }
        }
    }

    /// Kept separate so the layout policy can be checked without attempting
    /// to override the system's read-only VoiceOver environment value.
    static func usesMonthlyFlowDetails(dynamicTypeSize: DynamicTypeSize, voiceOverEnabled: Bool) -> Bool {
        dynamicTypeSize.isAccessibilitySize || voiceOverEnabled
    }

    /// Period totals cannot replace the chart's six separate months. Keep
    /// the same series, including zero and negative values, in a layout that
    /// can grow vertically and is readable without color or chart axes.
    private var monthlyFlowDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(report.monthlyFlows.suffix(6)), id: \.month) { flow in
                VStack(alignment: .leading, spacing: 4) {
                    Text(flow.month.formattedForReporting(
                        .dateTime.year().month(.wide),
                        calendar: calendar
                    ))
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    flowRow("history.income", flow.income)
                    flowRow("history.spent", flow.expense)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Read the observed preference for every amount, including when the
    /// chart is absent. Reading only the formatter's UserDefaults value does
    /// not establish this view's live privacy dependency.
    private func displayedAmount(_ money: Money) -> String {
        hidesAmounts ? MoneyAmountPrivacy.placeholder : formattedMoneyWithCurrencyCode(money)
    }

    /// A flow and its amount on one line where they fit; otherwise the amount
    /// goes beneath, whole, instead of breaking mid-number.
    private func flowRow(_ title: LocalizedStringKey, _ money: Money) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer()
                Text(maskingAmounts: displayedAmount(money)).monospacedDigit()
            }
            .lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(maskingAmounts: displayedAmount(money)).monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .font(.caption)
    }
}
