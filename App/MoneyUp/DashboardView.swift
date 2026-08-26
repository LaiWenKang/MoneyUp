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

    private struct CashDebtPosition {
        let cash: Money
        let debt: Money
        let netCash: Money
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingSafeToSpendBreakdown = false
    let onOpenLog: () -> Void
    let onOpenPlan: () -> Void

    init(
        onOpenLog: @escaping () -> Void = {},
        onOpenPlan: @escaping () -> Void = {}
    ) {
        self.onOpenLog = onOpenLog
        self.onOpenPlan = onOpenPlan
    }

    private var spendableAccounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.accountType != .brokerage && $0.accountType != .investment
        }
    }

    private var cashDebtPosition: DerivedValue<CashDebtPosition> {
        guard let currency = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        var cash = Decimal.zero
        var debt = Decimal.zero
        for account in spendableAccounts where account.currency == currency {
            switch model.displayBalanceResult(for: account) {
            case let .available(balance):
                if account.kind == .liability {
                    debt += balance.amount
                } else {
                    cash += balance.amount
                }
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }
        do {
            return .available(
                CashDebtPosition(
                    cash: try Money(cash, currency: currency),
                    debt: try Money(debt, currency: currency),
                    netCash: try Money(cash - debt, currency: currency)
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

    private var monthElapsed: Double {
        let calendar = Calendar.current
        let now = Date()
        guard let month = calendar.dateInterval(of: .month, for: now) else { return 0 }
        let span = month.end.timeIntervalSince(month.start)
        guard span > 0 else { return 0 }
        return min(max(now.timeIntervalSince(month.start) / span, 0), 1)
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
                    safeToSpendHero

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("dashboard.position_title", systemImage: "scale.3d")
                                .font(.headline)

                            switch cashDebtPosition {
                            case let .available(position):
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 10) {
                                        PositionMetric(
                                            title: "dashboard.cash_on_hand",
                                            value: formattedMoney(position.cash),
                                            systemImage: "banknote.fill",
                                            color: .accentColor
                                        )
                                        PositionMetric(
                                            title: "dashboard.card_loan_debt",
                                            value: formattedMoney(position.debt),
                                            systemImage: "creditcard.fill",
                                            color: .orange
                                        )
                                    }
                                    VStack(spacing: 10) {
                                        PositionMetric(
                                            title: "dashboard.cash_on_hand",
                                            value: formattedMoney(position.cash),
                                            systemImage: "banknote.fill",
                                            color: .accentColor
                                        )
                                        PositionMetric(
                                            title: "dashboard.card_loan_debt",
                                            value: formattedMoney(position.debt),
                                            systemImage: "creditcard.fill",
                                            color: .orange
                                        )
                                    }
                                }

                                MoneyUpPositionDiagram(
                                    cashAmount: position.cash.amount,
                                    debtAmount: position.debt.amount
                                )

                                LabeledContent("dashboard.net_cash") {
                                    Text(formattedMoney(position.netCash))
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                }
                            case let .unavailable(issue):
                                DerivedValueUnavailableView(issue: issue, prominent: true)
                            }

                            if case let .available(balances) = otherCurrencyBalances,
                               !balances.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("dashboard.other_currencies")
                                    Text(balances.map(formattedMoney).joined(separator: " · "))
                                        .monospacedDigit()
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                            } else if case let .unavailable(issue) = otherCurrencyBalances {
                                DerivedValueUnavailableView(issue: issue)
                            }

                            Text("dashboard.position_detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dashboard.monthly_budget")
                                .font(.headline)
                            switch budgetSummary {
                            case let .available(.some(summary)):
                                let ratio = budgetRatio(summary)
                                MoneyUpPaceBar(ratio: ratio, elapsed: monthElapsed)
                                Text(
                                    "\(formattedMoney(summary.spent)) / \(formattedMoney(summary.limit))"
                                )
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)

                                Label(
                                    budgetPaceKey(ratio: ratio),
                                    systemImage: budgetPaceSymbol(ratio: ratio)
                                )
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(ratio > 1 ? Color.red : Color.secondary)

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
                                Button {
                                    onOpenPlan()
                                } label: {
                                    Label("dashboard.set_budget", systemImage: "chart.pie.fill")
                                }
                                .buttonStyle(.bordered)
                                .tint(.accentColor)
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
                                MoneyUpIllustration("MoneyUpMoneyWorld", height: 132)
                                Text("dashboard.no_transactions")
                                    .font(.title3.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                Text("dashboard.no_transactions_detail")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                Button {
                                    onOpenLog()
                                } label: {
                                    Label("dashboard.log_first", systemImage: "plus.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.moneyUpAction)
                                .frame(maxWidth: .infinity)
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
            .background { MoneyUpBackdrop() }
            .navigationTitle("tab.today")
            .sheet(isPresented: $isShowingSafeToSpendBreakdown) {
                if case let .available(.some(breakdown)) = model.safeToSpendTodayResult() {
                    SafeToSpendBreakdownSheet(breakdown: breakdown)
                }
            }
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

    private var safeToSpendHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.22),
                            Color.moneyUpMist.opacity(0.40),
                            Color.moneyUpSurfaceElevated
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 14) {
                switch model.safeToSpendTodayResult() {
                case let .available(.some(breakdown)):
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 12) {
                                heroIllustration
                                safeToSpendCopy(breakdown)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 12) {
                                safeToSpendCopy(breakdown)
                                heroIllustration
                            }
                        }
                    }

                    Button {
                        isShowingSafeToSpendBreakdown = true
                    } label: {
                        Label(
                            "dashboard.safe_to_spend.show_math",
                            systemImage: "function"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                case .available(.none):
                    heroIllustration
                    Label("dashboard.safe_to_spend", systemImage: "sun.max.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Text("dashboard.safe_to_spend.needs_budget")
                        .font(.title3.weight(.semibold))
                    Text("dashboard.safe_to_spend.needs_budget_detail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        onOpenPlan()
                    } label: {
                        Label("dashboard.set_budget", systemImage: "chart.pie.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                case let .unavailable(issue):
                    Label("dashboard.safe_to_spend", systemImage: "sun.max.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    DerivedValueUnavailableView(issue: issue, prominent: true)
                }

                Divider()
                quickActions
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var heroIllustration: some View {
        Image("MoneyUpMoneyWorld")
            .resizable()
            .scaledToFit()
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 148 : 132)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityHidden(true)
    }

    private func safeToSpendCopy(
        _ breakdown: SafeToSpendBreakdown
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("dashboard.safe_to_spend", systemImage: "sun.max.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            Text(formattedMoney(breakdown.amountPerDay))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(
                    breakdown.amountPerDay.amount < .zero ? Color.red : Color.primary
                )
                .contentTransition(.numericText())
            Text("dashboard.safe_to_spend.per_day")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if breakdown.amountPerDay.amount < .zero {
                Label(
                    "dashboard.safe_to_spend.attention",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func budgetPaceKey(ratio: Double) -> LocalizedStringKey {
        if ratio > 1 { return "dashboard.budget_pace.over" }
        if ratio > monthElapsed + 0.05 { return "dashboard.budget_pace.ahead" }
        return "dashboard.budget_pace.within"
    }

    private func budgetPaceSymbol(ratio: Double) -> String {
        if ratio > 1 { return "exclamationmark.triangle.fill" }
        if ratio > monthElapsed + 0.05 { return "gauge.with.dots.needle.67percent" }
        return "checkmark.circle.fill"
    }

    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                logButton
                planButton
            }
            VStack(spacing: 10) {
                logButton
                planButton
            }
        }
    }

    private var logButton: some View {
        Button {
            onOpenLog()
        } label: {
            Label("dashboard.log_money", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.moneyUpAction)
    }

    private var planButton: some View {
        Button {
            onOpenPlan()
        } label: {
            Label("dashboard.plan_money", systemImage: "chart.pie.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
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

private struct SafeToSpendBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss
    let breakdown: SafeToSpendBreakdown

    private var displayedPeriodEnd: Date {
        breakdown.periodEnd.addingTimeInterval(-1)
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

                    DashboardCard {
                        VStack(spacing: 0) {
                            calculationRow(
                                "dashboard.safe_to_spend.budget_remaining",
                                value: formattedMoney(breakdown.eligibleBudgetRemaining),
                                symbol: "chart.pie.fill"
                            )
                            calculationDivider(operatorSymbol: "minus")
                            calculationRow(
                                "dashboard.safe_to_spend.commitments",
                                value: formattedMoney(breakdown.scheduledCommitments),
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

                    DashboardCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("dashboard.safe_to_spend.period", systemImage: "calendar")
                                .font(.headline)
                            Text(
                                "\(breakdown.periodStart.formatted(date: .abbreviated, time: .omitted)) – \(displayedPeriodEnd.formatted(date: .abbreviated, time: .omitted))"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }

                    DashboardCard {
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

struct DashboardCard<Content: View>: View {
    let content: Content
    let backgroundColor: Color

    init(
        backgroundColor: Color = .moneyUpSurfaceElevated,
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
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.10), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
    }
}
