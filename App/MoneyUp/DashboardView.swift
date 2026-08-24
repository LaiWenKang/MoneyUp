import MoneyUpCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private var spendableAccounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.accountType != .brokerage && $0.accountType != .investment
        }
    }

    private var availableBalance: Money? {
        guard let currency = model.profile?.baseCurrency else { return nil }
        var total = Decimal.zero
        for account in spendableAccounts where account.currency == currency {
            guard let balance = model.displayBalance(for: account) else { continue }
            total += account.kind == .liability ? -balance.amount : balance.amount
        }
        return try? Money(total, currency: currency)
    }

    /// Spendable money held outside the base currency. MoneyUp stores no
    /// exchange rates, so these balances are shown beside the headline figure
    /// instead of being folded into it.
    private var otherCurrencyBalances: [Money] {
        guard let base = model.profile?.baseCurrency else { return [] }
        var totals: [CurrencyCode: Decimal] = [:]

        for account in spendableAccounts {
            guard let currency = account.currency, currency != base,
                  let balance = model.displayBalance(for: account) else { continue }
            totals[currency, default: .zero] +=
                account.kind == .liability ? -balance.amount : balance.amount
        }

        return totals
            .compactMap { try? Money($0.value, currency: $0.key) }
            .filter { !$0.isZero }
            .sorted { $0.currency < $1.currency }
    }

    private var nextScheduledTransaction: ScheduledTransaction? {
        model.scheduledTransactions.min { $0.nextOccurrence < $1.nextOccurrence }
    }

    private var rootBudgetSummary: (spent: Money, limit: Money, ratio: Double)? {
        guard let currency = model.profile?.baseCurrency else { return nil }
        let rootIDs = Set(model.budgetNodes.filter { $0.parentID == nil }.map(\.id))
        let progress = model.budgetProgressThisMonth().filter { rootIDs.contains($0.node.id) }
        let limit = progress.compactMap(\.node.limit).reduce(Decimal.zero) { $0 + $1.amount }
        guard limit > .zero else { return nil }
        let spent = progress.reduce(Decimal.zero) { $0 + $1.spent.amount }
        let ratio = min(max(NSDecimalNumber(decimal: spent / limit).doubleValue, 0), 1)
        guard let spentMoney = try? Money(spent, currency: currency),
              let limitMoney = try? Money(limit, currency: currency) else { return nil }
        return (spentMoney, limitMoney, ratio)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    DashboardCard(backgroundColor: Color.accentColor.opacity(0.07)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("dashboard.safe_to_spend", systemImage: "checkmark.shield.fill")
                                .font(.headline)
                                .foregroundStyle(.tint)

                            Text(availableBalance.map(formattedMoney) ?? "—")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .contentTransition(.numericText())

                            Text("dashboard.available_detail")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if !otherCurrencyBalances.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("dashboard.other_currencies")
                                    Text(
                                        otherCurrencyBalances
                                            .map(formattedMoney)
                                            .joined(separator: " · ")
                                    )
                                    .monospacedDigit()
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dashboard.monthly_budget")
                                .font(.headline)
                            if let summary = rootBudgetSummary {
                                ProgressView(value: summary.ratio)
                                    .tint(summary.ratio >= 1 ? .red : .accentColor)
                                Text(
                                    "\(formattedMoney(summary.spent)) / \(formattedMoney(summary.limit))"
                                )
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            } else {
                                Text("dashboard.no_budget")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let upcoming = nextScheduledTransaction {
                        DashboardCard {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("dashboard.upcoming")
                                        .font(.headline)
                                    Text(
                                        upcoming.nextOccurrence,
                                        format: .dateTime.month().day()
                                    )
                                    .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.title2)
                            }
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
