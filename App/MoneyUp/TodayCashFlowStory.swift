import Charts
import MoneyUpCore
import SwiftUI

/// A partial month is labelled as such; this never compares it with a complete
/// month or combines unconverted currencies into a claimed spending trend.
struct TodayCashFlowStory: View {
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    let report: PeriodReport
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(formattedMoneyWithCurrencyCode(report.baseFlow.net))
                .moneyUpFinancialValue(.prominent)
            Text("dashboard.flow.net_to_date")
                .font(.caption).foregroundStyle(.secondary)
            Chart(Array(report.monthlyFlows.suffix(6)), id: \.month) { flow in
                BarMark(
                    x: .value(AppLocalization.string("chart.dimension.month"), flow.month, unit: .month),
                    y: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: flow.income.amount).doubleValue)
                )
                .foregroundStyle(by: .value(AppLocalization.string("history.income"), AppLocalization.string("history.income")))
                .position(by: .value(AppLocalization.string("chart.dimension.kind"), AppLocalization.string("history.income")))
                BarMark(
                    x: .value(AppLocalization.string("chart.dimension.month"), flow.month, unit: .month),
                    y: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: flow.expense.amount).doubleValue)
                )
                .foregroundStyle(by: .value(AppLocalization.string("history.spent"), AppLocalization.string("history.spent")))
                .position(by: .value(AppLocalization.string("chart.dimension.kind"), AppLocalization.string("history.spent")))
            }
            .chartForegroundStyleScale([
                AppLocalization.string("history.income"): Color.moneyUpChartSeries1,
                AppLocalization.string("history.spent"): Color.moneyUpChartSeries2
            ])
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .chartYAxis(hidesAmounts ? .hidden : .automatic)
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 130)
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .accessibilityHidden(true)
            HStack {
                Text("history.income")
                Spacer()
                Text(formattedMoneyWithCurrencyCode(report.baseFlow.income)).monospacedDigit()
            }.font(.caption)
            HStack {
                Text("history.spent")
                Spacer()
                Text(formattedMoneyWithCurrencyCode(report.baseFlow.expense)).monospacedDigit()
            }.font(.caption)
            if !report.foreignFlows.isEmpty {
                Text("dashboard.flow.other_currencies").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
