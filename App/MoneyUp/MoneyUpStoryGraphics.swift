import Charts
import MoneyUpCore
import SwiftUI

/// Compact visual rhythm shared by goals and read-only planning tools. The
/// neighboring text owns the value; the dial never replaces a financial label.
struct MoneyUpProgressDial: View {
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    let fraction: Double
    let systemImage: String

    private var progress: Double { fraction.isFinite ? min(max(fraction, 0), 1) : 0 }

    var body: some View {
        ZStack {
            Circle().stroke(Color.moneyUpMist, lineWidth: 7)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.moneyUpChartSeries1, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(MoneyUpMotion.animation(for: .stateChange, reduceMotion: reduceMotion), value: progress)
            Image(systemName: systemImage).font(.title3.weight(.semibold)).foregroundStyle(.tint)
        }
        .padding(5)
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Actual, signed flows share a zero baseline. Refunds and negative corrections
/// stay negative; currencies are never merged to make a prettier chart.
struct MoneyUpCashFlowGraphic: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let income: Money
    let expense: Money

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize, income.currency == expense.currency, !income.isZero || !expense.isZero {
            Chart {
                BarMark(
                    x: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: income.amount).doubleValue),
                    y: .value(AppLocalization.string("chart.dimension.category"), AppLocalization.string("transaction.income"))
                ).foregroundStyle(MoneyUpChartPalette.income)
                BarMark(
                    x: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: expense.amount).doubleValue),
                    y: .value(AppLocalization.string("chart.dimension.category"), AppLocalization.string("transaction.expense"))
                ).foregroundStyle(MoneyUpChartPalette.expense)
                RuleMark(x: .value(AppLocalization.string("chart.dimension.amount"), 0))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.automatic)
            .frame(height: 52)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}

struct MoneyUpFlowNode: Equatable {
    let title: String
    let symbol: String
}

/// A direction diagram complements editable controls without becoming a
/// second input model. It grows vertically at accessibility text sizes.
struct MoneyUpFlowDiagram: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let source: MoneyUpFlowNode
    let destination: MoneyUpFlowNode

    var body: some View {
        let vertical = dynamicTypeSize.isAccessibilitySize
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            node(source)
            Image(systemName: vertical ? "arrow.down" : "arrow.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tint).accessibilityHidden(true)
            node(destination)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: AppLocalization.string("flow.direction"), source.title, destination.title))
    }

    private func node(_ value: MoneyUpFlowNode) -> some View {
        HStack(spacing: 7) {
            Image(systemName: value.symbol).foregroundStyle(.tint).accessibilityHidden(true)
            Text(value.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(10)
        .background(Color.moneyUpSurface, in: RoundedRectangle(cornerRadius: 14))
    }
}
