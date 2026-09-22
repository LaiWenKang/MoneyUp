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
                .animation(MoneyUpMotion.animation(for: .financialValue, reduceMotion: reduceMotion), value: progress)
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
    let income: Money
    let expense: Money

    /// Two labeled, same-scale bars. A zero flow keeps its row so the pair is
    /// always comparable; the exact amounts are listed by the caller, so the
    /// graphic itself is decorative for assistive technology.
    var body: some View {
        if income.currency == expense.currency, !income.isZero || !expense.isZero {
            VStack(alignment: .leading, spacing: 6) {
                flowRow("transaction.income", amount: income.amount, color: MoneyUpChartPalette.income)
                flowRow("transaction.expense", amount: expense.amount, color: MoneyUpChartPalette.expense)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private var scale: Double {
        let largest = max(abs(income.amount), abs(expense.amount))
        return NSDecimalNumber(decimal: largest).doubleValue
    }

    private func fraction(_ amount: Decimal) -> CGFloat {
        guard scale > 0 else { return 0 }
        let value = NSDecimalNumber(decimal: abs(amount)).doubleValue / scale
        return CGFloat(min(max(value, 0), 1))
    }

    private func flowRow(_ title: LocalizedStringKey, amount: Decimal, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.14))
                    if amount != .zero {
                        Capsule()
                            .fill(color)
                            .frame(width: max(proxy.size.width * fraction(amount), 4))
                    }
                }
            }
            .frame(height: 10)
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
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: MoneyUpLayout.compactSpacing))
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
