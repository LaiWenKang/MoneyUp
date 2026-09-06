import MoneyUpCore
import SwiftUI

struct AssetsOverviewSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appReportingSnapshot) private var reportingSnapshot
    @AppStorage(MoneyAmountPrivacy.storageKey) private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var isCapturing = false
    @State private var didCapture = false
    @State private var errorMessage: String?
    let oldestPositionPriceDate: Date?

    var body: some View {
        let _ = hidesAmounts
        let now = reportingSnapshot?.instant ?? model.currentDateForUserAction()
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Label("assets.account_net_worth", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                switch model.netWorthByCurrencyResult() {
                case let .available(amounts):
                    ForEach(amounts, id: \.currency) { value in
                        if hidesAmounts { Text(value.currency.value).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        Text(formattedMoneyWithCurrencyCode(value)).moneyUpFinancialValue(.hero)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    estimate(amounts: amounts)
                case let .unavailable(issue):
                    DerivedValueUnavailableView(issue: issue, prominent: true)
                }
                RestrictedStoredValueSummary(result: model.restrictedAllowanceValueByCurrencyResult(asOf: now))
                if let oldestPositionPriceDate {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("assets.oldest_position_price").font(.caption)
                        Text(oldestPositionPriceDate, format: .dateTime.year().month().day()).font(.caption)
                        if model.investmentHoldings.contains(where: {
                            $0.positionAccountID != nil && $0.quantity > .zero && $0.isPriceStale(relativeTo: now, calendar: model.reportingCalendar)
                        }) { Text("holding.stale").font(.caption).foregroundStyle(.orange) }
                    }.foregroundStyle(.secondary)
                }
                Button { Task { await capture() } } label: {
                    HStack {
                        Label("assets.capture_snapshot", systemImage: "camera.aperture")
                        if isCapturing { ProgressView() }
                    }
                }
                .disabled(isCapturing)
                .buttonStyle(.borderless)
                if didCapture { Label("assets.snapshot_saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint) }
            }.padding(.vertical, 8)
        } footer: {
            MoneyUpExplainer("assets.account_net_worth_note")
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    @ViewBuilder
    private func estimate(amounts: [Money]) -> some View {
        switch model.estimatedNetWorthResult() {
        case let .available(.some(value)):
            VStack(alignment: .leading, spacing: 3) {
                Text("≈ \(formattedMoney(value.total))").moneyUpFinancialValue(.standard)
                HStack(spacing: 4) {
                    Text("fx.rates_as_of")
                    Text(value.conversionAsOf, format: .dateTime.year().month().day())
                }.font(.caption)
            }.foregroundStyle(.secondary)
        case .available(nil):
            if amounts.filter({ !$0.isZero }).count > 1 {
                Text("fx.net_worth_complete_rate_needed").font(.caption).foregroundStyle(.secondary)
            }
        case let .unavailable(issue):
            DerivedValueUnavailableView(issue: issue)
        }
    }

    private func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        didCapture = false
        defer { isCapturing = false }
        do { try await model.captureNetWorthSnapshot(); didCapture = true }
        catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}
