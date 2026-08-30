import MoneyUpCore
import SwiftUI
import UIKit

enum DashboardReportingClockPolicy {
    /// Uses the book's reporting calendar so daylight-saving transitions and a
    /// reporting zone that differs from the device zone never become a fixed
    /// 86,400-second approximation.
    static func nextRefresh(
        after date: Date,
        calendar: Calendar,
        scheduledOccurrences: [Date] = []
    ) -> Date? {
        guard let dayEnd = calendar.dateInterval(of: .day, for: date)?.end else {
            return nil
        }
        guard let nextOccurrence = scheduledOccurrences
            .filter({ $0 >= date })
            .min() else { return dayEnd }
        // Move just beyond an occurrence because `occurrence(onOrAfter:)`
        // intentionally includes an occurrence exactly equal to its argument.
        return min(dayEnd, nextOccurrence.addingTimeInterval(1))
    }
}

struct DashboardView: View {
    @MainActor
    struct UpcomingSchedule {
        let transaction: ScheduledTransaction
        let occurrence: Date

        var signedAmount: String {
            let sign = transaction.kind == .expense ? "−" : "+"
            return sign + formattedMoney(transaction.amount)
        }
    }

    struct CashDebtPosition {
        let cash: Money
        let debt: Money
        let netCash: Money
    }

    @Environment(AppModel.self) var model
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @State var isShowingFlexibleTodayBreakdown = false
    @State var reportingNow: Date?
    @State var reportingClockGeneration = 0
    let onOpenLog: () -> Void
    let onOpenPlan: () -> Void
    let onOpenAssets: () -> Void

    init(
        initialReportingDate: Date? = nil,
        onOpenLog: @escaping () -> Void = {},
        onOpenPlan: @escaping () -> Void = {},
        onOpenAssets: @escaping () -> Void = {}
    ) {
        _reportingNow = State(initialValue: initialReportingDate)
        self.onOpenLog = onOpenLog
        self.onOpenPlan = onOpenPlan
        self.onOpenAssets = onOpenAssets
    }

    var spendableAccounts: [LedgerAccount] {
        model.allUserAccounts.filter {
            $0.systemRole == nil
                && $0.accountType != .brokerage
                && $0.accountType != .investment
        }
    }

    var cashDebtPosition: DerivedValue<CashDebtPosition> {
        guard let currency = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        var cash = Decimal.zero
        var debt = Decimal.zero
        do {
            for account in spendableAccounts where account.currency == currency {
                switch model.displayBalanceResult(for: account) {
                case let .available(balance):
                    if account.kind == .liability {
                        debt = try CheckedDecimal.adding(debt, balance.amount)
                    } else {
                        cash = try CheckedDecimal.adding(cash, balance.amount)
                    }
                case let .unavailable(issue):
                    return .unavailable(issue)
                }
            }
            return .available(
                CashDebtPosition(
                    cash: try Money(cash, currency: currency),
                    debt: try Money(debt, currency: currency),
                    netCash: try Money(
                        CheckedDecimal.subtracting(cash, debt),
                        currency: currency
                    )
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "dashboard-cash-debt-position",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    /// Liquid positions outside the base currency. MoneyUp stores no exchange
    /// rates, so these balances are shown beside the headline figure instead
    /// of being folded into it.
    var otherCurrencyBalances: DerivedValue<[Money]> {
        guard let base = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        var totals: [CurrencyCode: Decimal] = [:]

        for account in spendableAccounts {
            guard let currency = account.currency, currency != base else { continue }
            switch model.displayBalanceResult(for: account) {
            case let .available(balance):
                do {
                    totals[currency] = try CheckedDecimal.adding(
                        totals[currency] ?? .zero,
                        account.kind == .liability
                            ? -balance.amount
                            : balance.amount
                    )
                } catch {
                    DerivedValueDiagnostics.record(
                        .amountCalculationFailed,
                        operation: "dashboard-other-currency-position",
                        error: error
                    )
                    return .unavailable(.amountCalculationFailed)
                }
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }

        var balances: [Money] = []
        for (currency, amount) in totals.sorted(by: { $0.key < $1.key }) {
            switch DerivedValue<Money>.money(
                amount,
                currency: currency,
                operation: "dashboard-other-currency-position"
            ) {
            case let .available(money):
                if !money.isZero { balances.append(money) }
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }
        return .available(balances)
    }

    var nextScheduledTransaction: UpcomingSchedule? {
        let now = reportingDate
        return model.scheduledTransactions
            .compactMap { transaction in
                transaction.occurrence(
                    onOrAfter: now,
                    calendar: model.reportingCalendar
                ).map {
                    UpcomingSchedule(transaction: transaction, occurrence: $0)
                }
            }
            .min { $0.occurrence < $1.occurrence }
    }

    var budgetSummary: DerivedValue<BudgetPlanSummary?> {
        model.budgetPlanSummaryThisMonthResult(asOf: reportingDate)
    }

    var monthElapsed: Double {
        let calendar = model.reportingCalendar
        let now = reportingDate
        guard let month = calendar.dateInterval(of: .month, for: now) else { return 0 }
        let span = month.end.timeIntervalSince(month.start)
        guard span > 0 else { return 0 }
        return min(max(now.timeIntervalSince(month.start) / span, 0), 1)
    }

    func budgetRatio(
        _ summary: BudgetPlanSummary
    ) -> DerivedValue<Double> {
        moneyUpPaceRatio(
            spent: summary.spent.amount,
            limit: summary.limit.amount,
            operation: "dashboard-budget-ratio"
        )
    }
}

private struct PositionMetric: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            MoneyUpSymbolBadge(systemImage: systemImage, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct FlexibleTodayBreakdownSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let breakdown: FlexibleTodayBreakdown

    private var displayedPeriodEnd: Date {
        breakdown.periodEnd.addingTimeInterval(-1)
    }

    private var displayedPeriodDescription: String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let start = breakdown.periodStart.formattedForReporting(
            style,
            calendar: model.reportingCalendar
        )
        let end = displayedPeriodEnd.formattedForReporting(
            style,
            calendar: model.reportingCalendar
        )
        return "\(start) – \(end)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        MoneyUpBrandMark()
                            .frame(width: 54, height: 54)
                            .padding(10)
                            .background(Color.accentColor.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("dashboard.safe_to_spend")
                                .font(.headline)
                            Text(formattedMoney(breakdown.amountPerDay))
                                .font(.largeTitle.bold().monospacedDigit())
                        }
                    }

                    MoneyUpCard {
                        VStack(spacing: 0) {
                            calculationRow(
                                "dashboard.safe_to_spend.budget_remaining",
                                value: formattedMoney(breakdown.flexibleBudgetRemaining),
                                symbol: "chart.pie.fill"
                            )
                            calculationDivider(operatorSymbol: "minus")
                            calculationRow(
                                "dashboard.safe_to_spend.commitments",
                                value: formattedMoney(breakdown.flexibleCommitments),
                                symbol: "calendar.badge.clock"
                            )
                            calculationDivider(operatorSymbol: "equal")
                            calculationRow(
                                "dashboard.safe_to_spend.period_available",
                                value: formattedMoney(breakdown.availableForRemainingPeriod),
                                symbol: "calendar"
                            )
                            calculationDivider(operatorSymbol: "divide")
                            calculationRow(
                                "dashboard.safe_to_spend.days_remaining",
                                value: breakdown.remainingDayCount.formatted(),
                                symbol: "sun.max.fill"
                            )
                        }
                    }

                    MoneyUpCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("dashboard.safe_to_spend.period", systemImage: "calendar")
                                .font(.headline)
                            Text(displayedPeriodDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    MoneyUpCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(
                                "dashboard.safe_to_spend.exclusions",
                                systemImage: "info.circle.fill"
                            )
                            .font(.headline)

                            exclusionRow("dashboard.safe_to_spend.exclusion_unbudgeted")
                            exclusionRow("dashboard.safe_to_spend.exclusion_income")
                            exclusionRow("dashboard.safe_to_spend.no_rates")
                            exclusionRow("dashboard.safe_to_spend.schedule_assumption")

                            ForEach(
                                breakdown.excludedForeignSpending,
                                id: \.currency
                            ) { money in
                                HStack {
                                    Label(
                                        "dashboard.safe_to_spend.foreign_spending_excluded",
                                        systemImage: "globe"
                                    )
                                    Spacer(minLength: 12)
                                    Text(formattedMoney(money))
                                        .monospacedDigit()
                                }
                                .font(.subheadline)
                                .accessibilityElement(children: .combine)
                            }

                            ForEach(
                                breakdown.excludedForeignCommitments,
                                id: \.currency
                            ) { money in
                                HStack {
                                    Label(
                                        "dashboard.safe_to_spend.foreign_excluded",
                                        systemImage: "globe"
                                    )
                                    Spacer(minLength: 12)
                                    Text(formattedMoney(money))
                                        .monospacedDigit()
                                }
                                .font(.subheadline)
                                .accessibilityElement(children: .combine)
                            }

                            if breakdown.schedulesNeedingReview > 0 {
                                Label(
                                    String(
                                        format: String(
                                            localized: "dashboard.safe_to_spend.review_schedules"
                                        ),
                                        breakdown.schedulesNeedingReview
                                    ),
                                    systemImage: "exclamationmark.calendar"
                                )
                                .font(.subheadline)
                            }
                        }
                    }
                }
                .padding()
            }
            .background { MoneyUpBackdrop() }
            .navigationTitle("dashboard.safe_to_spend.how")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func calculationRow(
        _ title: LocalizedStringKey,
        value: String,
        symbol: String
    ) -> some View {
        HStack(spacing: 12) {
            MoneyUpSymbolBadge(systemImage: symbol)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func calculationDivider(operatorSymbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: operatorSymbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 44)
            Divider()
        }
        .accessibilityHidden(true)
    }

    private func exclusionRow(_ key: LocalizedStringKey) -> some View {
        Label(key, systemImage: "circle.dashed")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
