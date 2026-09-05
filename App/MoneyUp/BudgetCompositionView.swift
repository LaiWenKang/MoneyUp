import Charts
import MoneyUpCore
import SwiftUI

/// A non-overlapping view of root allocations. The bounded Other bucket is
/// display-only and never becomes a category or an input to budget arithmetic.
struct BudgetCompositionView: View {
    private struct Segment: Identifiable {
        let id: String
        let name: String
        let amount: Money
        let node: BudgetNode?
        let colorIndex: Int
    }

    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @State private var selectedPosition: Double?
    @State private var selectedID: String?
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    let progress: [BudgetProgress]
    var allowsEditing = true
    var showsTitle = true
    let onEdit: (BudgetNode) -> Void

    private var segments: [Segment] {
        let roots = progress.filter { $0.node.parentID == nil && ($0.effectiveLimit?.amount ?? .zero) > .zero }
            .sorted { ($0.effectiveLimit?.amount ?? .zero) > ($1.effectiveLimit?.amount ?? .zero) }
        let capacity = MoneyUpChartPalette.ordered.count
        let visibleCount = roots.count <= capacity ? roots.count : capacity - 1
        let visible = roots.prefix(visibleCount).sorted {
            $0.node.name == $1.node.name ? $0.node.id.uuidString < $1.node.id.uuidString : $0.node.name < $1.node.name
        }
        var result = visible.enumerated().compactMap { index, item -> Segment? in
            guard let limit = item.effectiveLimit else { return nil }
            return Segment(id: item.node.id.uuidString, name: item.node.name, amount: limit, node: item.node, colorIndex: index)
        }
        if let first = roots.dropFirst(visibleCount).first?.effectiveLimit {
            do {
                let total = try roots.dropFirst(visibleCount).reduce(Money.zero(currency: first.currency)) { sum, item in
                    guard let amount = item.effectiveLimit else { return sum }
                    return try sum.adding(amount)
                }
                result.append(Segment(id: "other", name: AppLocalization.string("insights.other_category"), amount: total, node: nil, colorIndex: capacity - 1))
            } catch { return [] }
        }
        return result
    }

    var body: some View {
        let segments = self.segments
        let selected = segments.first { $0.id == selectedID } ?? segments.first
        if progress.contains(where: { $0.node.parentID == nil && ($0.effectiveLimit?.amount ?? .zero) < .zero }) {
            Label("budget.composition_deficit", systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
        } else if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if showsTitle { Text("budget.composition").font(.headline) }
                Chart(segments) { segment in
                    BarMark(
                        x: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: segment.amount.amount).doubleValue),
                        y: .value(AppLocalization.string("chart.dimension.budget"), "budget"),
                        stacking: .standard
                    )
                    .foregroundStyle(MoneyUpChartPalette.ordered[segment.colorIndex])
                    .accessibilityLabel(segment.name)
                    .accessibilityValue(accessibleFormattedMoney(segment.amount))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartXSelection(value: $selectedPosition)
                .frame(height: 40)
                .accessibilityLabel("budget.composition")
                .accessibilityHidden(hidesAmounts)
                .animation(MoneyUpMotion.animation(for: .stateChange, reduceMotion: reduceMotion), value: segments.map { $0.amount.amount })
                .onChange(of: selectedPosition) { _, value in
                    guard let value else { return }
                    var end = 0.0
                    for segment in segments {
                        end += NSDecimalNumber(decimal: segment.amount.amount).doubleValue
                        if value <= end { selectedID = segment.id; return }
                    }
                    selectedID = segments.last?.id
                }
                if let selected {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            selectionLabel(selected)
                            Spacer()
                            if allowsEditing, let node = selected.node { Button("budget.edit") { onEdit(node) } }
                        }
                        VStack(alignment: .leading) {
                            selectionLabel(selected)
                            if allowsEditing, let node = selected.node { Button("budget.edit") { onEdit(node) } }
                        }
                    }
                }
                Text("budget.composition_hint").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else {
            Text("budget.composition_empty").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func selectionLabel(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(segment.name).font(.subheadline.weight(.semibold))
            Text(formattedMoney(segment.amount)).font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}
