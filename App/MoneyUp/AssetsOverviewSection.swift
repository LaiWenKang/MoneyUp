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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("assets.account_net_worth", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    MoneyUpExplainer("assets.account_net_worth_note").font(.footnote)
                }
                switch model.netWorthByCurrencyResult() {
                case let .available(amounts):
                    ForEach(amounts, id: \.currency) { value in
                        if hidesAmounts { Text(value.currency.value).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        Text(formattedMoneyWithCurrencyCode(value)).moneyUpFinancialValue(.hero)
                            .fixedSize(horizontal: false, vertical: true)
                            // VoiceOver hears what the figure is, not a bare number.
                            .accessibilityLabel(Text("assets.account_net_worth"))
                            .accessibilityValue(Text(accessibleFormattedMoney(value)))
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
                        }) { Text("holding.stale").font(.caption).foregroundStyle(Color.moneyUpWarning) }
                    }.foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
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
                    Text(value.conversionAsOf.formattedForReporting(.dateTime.year().month().day(), calendar: model.reportingCalendar))
                }.font(.caption)
            }.foregroundStyle(.secondary)
        case .available(nil):
            if amounts.filter({ !$0.isZero }).count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label("fx.total_needs_rates", systemImage: "arrow.left.arrow.right.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    MoneyUpExplainer("fx.net_worth_complete_rate_needed").font(.caption)
                }
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


/// Snapshot lives in the toolbar as a camera glyph; the confirmation is a
/// brief label that replaces the glyph, then returns.
struct AssetsSnapshotToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCapturing = false
    @State private var didCapture = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task { await capture() }
        } label: {
            if isCapturing {
                ProgressView()
            } else if didCapture {
                Label("assets.snapshot_saved", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
            } else {
                Label("assets.capture_snapshot", systemImage: "camera.aperture")
            }
        }
        .disabled(isCapturing)
        .accessibilityIdentifier("assets-capture-snapshot")
        .animation(MoneyUpMotion.animation(for: .confirmation, reduceMotion: reduceMotion), value: didCapture)
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            try await model.captureNetWorthSnapshot()
            didCapture = true
            try? await Task.sleep(for: .seconds(2))
            didCapture = false
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}
