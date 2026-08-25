import MoneyUpCore
import SwiftUI

struct DashboardView: View {
    @MainActor
    private struct UpcomingSchedule {
        let transaction: ScheduledTransaction
        let occurrence: Date

        var signedAmount: String {
            let sign = transaction.kind == .expense ? "−" : "+"
            return sign + formattedMoney(transaction.amount)
        }
    }

    @EnvironmentObject private var model: AppModel

    private var spendableAccounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.accountType != .brokerage && $0.accountType != .investment
        }
    }

    private var liquidPosition: DerivedValue<Money> {
        guard let currency = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        var total = Decimal.zero
        for account in spendableAccounts where account.currency == currency {
            switch model.displayBalanceResult(for: account) {
            case let .available(balance):
                total += account.kind == .liability ? -balance.amount : balance.amount
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }
        return .money(
            total,
            currency: currency,
            operation: "dashboard-liquid-position"
        )
    }

    /// Liquid positions outside the base currency. MoneyUp stores no exchange
    /// rates, so these balances are shown beside the headline figure instead
    /// of being folded into it.
    private var otherCurrencyBalances: DerivedValue<[Money]> {
        guard let base = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        var totals: [CurrencyCode: Decimal] = [:]

        for account in spendableAccounts {
            guard let currency = account.currency, currency != base else { continue }
            switch model.displayBalanceResult(for: account) {
            case let .available(balance):
                totals[currency, default: .zero] +=
                    account.kind == .liability ? -balance.amount : balance.amount
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

    private var nextScheduledTransaction: UpcomingSchedule? {
        let now = Date()
        return model.scheduledTransactions
            .compactMap { transaction in
                transaction.occurrence(onOrAfter: now).map {
                    UpcomingSchedule(transaction: transaction, occurrence: $0)
                }
            }
            .min { $0.occurrence < $1.occurrence }
    }

    private var budgetSummary: DerivedValue<BudgetPlanSummary?> {
        model.budgetPlanSummaryThisMonthResult()
    }

    private func budgetRatio(_ summary: BudgetPlanSummary) -> Double {
        guard summary.limit.amount > .zero else {
            return summary.spent.amount > .zero ? 1 : 0
        }
        return NSDecimalNumber(
            decimal: summary.spent.amount / summary.limit.amount
        ).doubleValue
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    DashboardCard(backgroundColor: Color.accentColor.opacity(0.07)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("dashboard.liquid_position", systemImage: "banknote.fill")
                                .font(.headline)
                                .foregroundStyle(.tint)

                            switch liquidPosition {
                            case let .available(position):
                                Text(formattedMoney(position))
                                    .font(
                                        .system(
                                            .largeTitle,
                                            design: .rounded,
                                            weight: .bold
                                        )
                                    )
                                    .contentTransition(.numericText())
                            case let .unavailable(issue):
                                DerivedValueUnavailableView(
                                    issue: issue,
                                    prominent: true
                                )
                            }

                            Text("dashboard.available_detail")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if case let .available(balances) = otherCurrencyBalances,
                               !balances.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("dashboard.other_currencies")
                                    Text(
                                        balances
                                            .map(formattedMoney)
                                            .joined(separator: " · ")
                                    )
                                    .monospacedDigit()
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                            } else if case let .unavailable(issue) = otherCurrencyBalances {
                                DerivedValueUnavailableView(issue: issue)
                            }
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dashboard.monthly_budget")
                                .font(.headline)
                            switch budgetSummary {
                            case let .available(.some(summary)):
                                let ratio = budgetRatio(summary)
                                ProgressView(value: min(max(ratio, 0), 1))
                                    .tint(ratio >= 1 ? .red : .accentColor)
                                Text(
                                    "\(formattedMoney(summary.spent)) / \(formattedMoney(summary.limit))"
                                )
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)

                                if summary.unbudgetedSpent.amount > .zero {
                                    HStack {
                                        Text("dashboard.unbudgeted_spending")
                                        Spacer()
                                        Text(formattedMoney(summary.unbudgetedSpent))
                                            .monospacedDigit()
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityElement(children: .combine)
                                }
                                switch model.excludedForeignSpendingThisMonthResult() {
                                case let .available(foreignSpending):
                                    ForEach(foreignSpending, id: \.currency) { money in
                                        HStack {
                                            Text("plan.foreign_not_counted")
                                            Spacer()
                                            Text(formattedMoney(money))
                                                .monospacedDigit()
                                        }
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                        .accessibilityElement(children: .combine)
                                    }
                                case let .unavailable(issue):
                                    DerivedValueUnavailableView(issue: issue)
                                }
                            case .available(.none):
                                Text("dashboard.no_budget")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            case let .unavailable(issue):
                                DerivedValueUnavailableView(issue: issue)
                            }
                        }
                    }

                    if let upcoming = nextScheduledTransaction {
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(
                                    "dashboard.upcoming",
                                    systemImage: "calendar.badge.clock"
                                )
                                .font(.headline)

                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(upcoming.transaction.name)
                                            .fontWeight(.semibold)
                                            .lineLimit(1)
                                        Text(
                                            upcoming.occurrence,
                                            format: .dateTime.month().day().year()
                                        )
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(upcoming.signedAmount)
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(
                                            upcoming.transaction.kind == .income
                                                ? Color.green
                                                : Color.primary
                                        )
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    DashboardCard {
                        VStack(spacing: 0) {
                            NavigationLink {
                                InsightsView()
                            } label: {
                                Label("dashboard.open_insights", systemImage: "chart.bar.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 6)

                            Divider()

                            NavigationLink {
                                AssetsView()
                            } label: {
                                Label("dashboard.open_assets", systemImage: "wallet.bifold.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 6)
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dashboard.recent")
                                .font(.headline)
                            if model.entries.isEmpty {
                                ContentUnavailableView(
                                    "dashboard.no_transactions",
                                    systemImage: "list.bullet.rectangle",
                                    description: Text("dashboard.no_transactions_detail")
                                )
                            } else {
                                ForEach(Array(model.entries.prefix(5))) { entry in
                                    TransactionRow(entry: entry)
                                    if entry.id != model.entries.prefix(5).last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }

                    DashboardCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("dashboard.private_by_design")
                                    .font(.headline)
                                Text("dashboard.privacy_detail")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("tab.today")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Label("settings.title", systemImage: "gearshape")
                    }
                }
            }
        }
    }
}

struct DashboardCard<Content: View>: View {
    let content: Content
    let backgroundColor: Color

    init(
        backgroundColor: Color = Color(.secondarySystemGroupedBackground),
        @ViewBuilder content: () -> Content
    ) {
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .contain)
    }
}
