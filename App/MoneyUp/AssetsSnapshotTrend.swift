import Charts
import MoneyUpCore
import SwiftUI

struct NetWorthHistoryPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let money: Money
}

enum NetWorthHistoryPresentation {
    static func points(_ snapshots: [NetWorthSnapshot], currency: CurrencyCode, limit: Int = 60) -> [NetWorthHistoryPoint] {
        guard limit > 0 else { return [] }
        let values = snapshots.compactMap { snapshot -> NetWorthHistoryPoint? in
            guard let money = snapshot.amounts.first(where: { $0.money.currency == currency })?.money else { return nil }
            return NetWorthHistoryPoint(id: snapshot.id, date: snapshot.capturedAt, money: money)
        }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        return Array(values.suffix(limit))
    }
}

struct AssetsSnapshotTrend: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var currencyCode: String?
    @State private var selectedDate: Date?
    @State private var selectedID: UUID?

    private var currencies: [CurrencyCode] {
        Set(model.netWorthSnapshots.flatMap { $0.amounts.map { $0.money.currency } }).sorted()
    }
    private var currency: CurrencyCode? {
        currencies.first { $0.value == currencyCode } ?? currencies.first { $0 == model.profile?.baseCurrency } ?? currencies.first
    }
    private var points: [NetWorthHistoryPoint] {
        currency.map { NetWorthHistoryPresentation.points(model.netWorthSnapshots, currency: $0) } ?? []
    }
    private var selected: NetWorthHistoryPoint? { points.first { $0.id == selectedID } ?? points.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if currencies.count > 1 {
                Picker("transaction.currency", selection: Binding(
                    get: { currency?.value ?? "" }, set: { currencyCode = $0; selectedID = nil; selectedDate = nil }
                )) {
                    ForEach(currencies, id: \.self) { Text($0.value).tag($0.value) }
                }.pickerStyle(.menu)
            }
            if let selected {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formattedMoneyWithCurrencyCode(selected.money)).moneyUpFinancialValue(.prominent)
                        Text(selected.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(selected.id == points.first?.id).accessibilityLabel("assets.snapshot_previous")
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(selected.id == points.last?.id).accessibilityLabel("assets.snapshot_next")
                }
                .buttonStyle(.borderless)
                Chart(points) { point in
                    LineMark(x: .value(AppLocalization.string("chart.dimension.date"), point.date), y: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: point.money.amount).doubleValue))
                        .foregroundStyle(Color.moneyUpChartSeries1)
                        .interpolationMethod(.linear)
                    PointMark(x: .value(AppLocalization.string("chart.dimension.date"), point.date), y: .value(AppLocalization.string("chart.dimension.amount"), NSDecimalNumber(decimal: point.money.amount).doubleValue))
                        .foregroundStyle(Color.moneyUpChartSeries1)
                    if point.id == selected.id {
                        RuleMark(x: .value(AppLocalization.string("chart.dimension.date"), point.date))
                            .lineStyle(StrokeStyle(lineWidth: MoneyUpChartSelectionPolicy.lineWidth, dash: MoneyUpChartSelectionPolicy.dash))
                            .foregroundStyle(Color.primary)
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxis(hidesAmounts ? .hidden : .automatic)
                .frame(height: 150)
                .accessibilityHidden(true)
                .onChange(of: selectedDate) { _, date in
                    guard let date else { return }
                    selectedID = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.id
                }
                Text("assets.snapshot_chart_detail").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func step(_ direction: Int) {
        guard let selected, let index = points.firstIndex(where: { $0.id == selected.id }) else { return }
        let destination = index + direction
        guard points.indices.contains(destination) else { return }
        selectedDate = nil
        selectedID = points[destination].id
    }
}
