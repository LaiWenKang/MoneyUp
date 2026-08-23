import MoneyUpCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private var availableBalance: Money? {
        guard let currency = model.profile?.baseCurrency else { return nil }
        var total = Decimal.zero
        for account in model.userAccounts
        where account.currency == currency
            && account.accountType != .brokerage
            && account.accountType != .investment {
            guard let balance = model.displayBalance(for: account) else { continue }
            total += account.kind == .liability ? -balance.amount : balance.amount
        }
        return try? Money(total, currency: currency)
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
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("dashboard.safe_to_spend", systemImage: "checkmark.shield.fill")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            Text(availableBalance.map(formattedMoney) ?? "—")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .contentTransition(.numericText())

                            Text("dashboard.available_detail")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
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

                    if !model.scheduledTransactions.isEmpty {
                        DashboardCard {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("dashboard.upcoming")
                                        .font(.headline)
                                    Text(
                                        model.scheduledTransactions[0].nextOccurrence,
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

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .contain)
    }
}
