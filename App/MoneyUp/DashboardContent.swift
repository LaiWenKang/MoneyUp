import MoneyUpCore
import SwiftUI

extension DashboardView {
    /// Today answers one question: what is left, in the categories this person
    /// steers by. Anything another tab already owns — the transaction list,
    /// the account list, the static privacy explainer — is deliberately not
    /// repeated here.
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    headline
                    MoneyUpCard { quickActions }
                    IntelligenceSummaryLink()
                    positionCard
                    monthlyBudgetCard
                    upcomingCard
                    insightsCard
                    firstRunCard
                }
                .padding()
            }
            .background { MoneyUpBackdrop() }
            .navigationTitle("tab.today")
            .sheet(isPresented: $isShowingFlexibleTodayBreakdown) {
                if case let .available(.available(breakdown)) = model.flexibleTodayResult(
                    asOf: reportingDate
                ) {
                    FlexibleTodayBreakdownSheet(breakdown: breakdown)
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
        // Anchored outside the stack so it never competes with the Today
        // arithmetic sheet presented from within it.
        .sheet(isPresented: $isEditingPins) {
            PinnedBudgetEditorSheet()
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
        .task(id: reportingClockTaskID) {
            await refreshAtReportingDayBoundaries()
        }
        .background {
            if scenePhase == .active,
               !model.requiresAuthenticationPrivacyCover,
               model.state == .ready {
                // `onAppear` is an honest SwiftUI hierarchy-publication proxy.
                // It deliberately does not claim that Core Animation presented
                // a pixel; physical Instruments collection owns that distinction.
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                    .onAppear {
                        model.finishUnlockToFirstUsefulContentMeasurement(
                            outcome: .success
                        )
                    }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            restartReportingClock()
        }
        .onChange(of: model.scheduledTransactions) { _, _ in
            restartReportingClock()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification
            )
        ) { _ in
            restartReportingClock()
        }
    }

    /// Pinned categories lead once the user has chosen any; until then the
    /// whole-book discretionary figure keeps the top of the screen so a new
    /// book is not a blank board.
    @ViewBuilder
    var headline: some View {
        if model.pinnedBudgetNodes.isEmpty {
            safeToSpendHero
            pinnedBoard
        } else {
            pinnedBoard
            safeToSpendSummary
        }
    }

    var pinnedBoard: some View {
        PinnedBudgetBoard(
            reportingDate: reportingDate,
            monthElapsed: monthElapsed,
            onOpenPlan: onOpenPlan,
            isEditingPins: $isEditingPins
        )
    }

    var positionCard: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("dashboard.position_title", systemImage: "scale.3d")
                    .font(.headline)

                switch cashDebtPosition {
                case let .available(position):
                    positionMetrics(position)
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

                otherCurrencies
                Text("dashboard.position_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func positionMetrics(_ position: CashDebtPosition) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cashMetric(position)
                debtMetric(position)
            }
            VStack(spacing: 10) {
                cashMetric(position)
                debtMetric(position)
            }
        }
    }

    private func cashMetric(_ position: CashDebtPosition) -> some View {
        PositionMetric(
            title: "dashboard.cash_on_hand",
            value: formattedMoney(position.cash),
            systemImage: "banknote.fill",
            color: .accentColor
        )
    }

    private func debtMetric(_ position: CashDebtPosition) -> some View {
        PositionMetric(
            title: "dashboard.card_loan_debt",
            value: formattedMoney(position.debt),
            systemImage: "creditcard.fill",
            color: .orange
        )
    }

    /// Money held outside the base currency is listed on its own, never folded
    /// into the headline figure, because MoneyUp does not invent a rate.
    @ViewBuilder
    private var otherCurrencies: some View {
        switch otherCurrencyBalances {
        case let .available(balances) where !balances.isEmpty:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("dashboard.other_currencies")
                Text(
                    balances
                        .map(formattedMoneyWithCurrencyCode)
                        .joined(separator: " · ")
                )
                .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .available:
            EmptyView()
        case let .unavailable(issue):
            DerivedValueUnavailableView(issue: issue)
        }
    }

    var monthlyBudgetCard: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("dashboard.monthly_budget")
                    .font(.headline)
                switch budgetSummary {
                case let .available(.some(summary)):
                    budgetProgress(summary)
                    foreignSpendingNotice
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
    }

    @ViewBuilder
    private func budgetProgress(_ summary: BudgetPlanSummary) -> some View {
        let ratioResult = budgetRatio(summary)
        if case let .available(ratio) = ratioResult {
            MoneyUpPaceBar(
                ratio: ratio,
                elapsed: monthElapsed,
                announcesStatus: false
            )
        } else if case let .unavailable(issue) = ratioResult {
            DerivedValueUnavailableView(issue: issue)
        }
        Text("\(formattedMoney(summary.spent)) / \(formattedMoney(summary.limit))")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        if case let .available(ratio) = ratioResult {
            Label(
                budgetPaceKey(ratio: ratio),
                systemImage: budgetPaceSymbol(ratio: ratio)
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ratio > 1 ? Color.red : Color.secondary)
        }
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
    }

    /// Spending in another currency is never converted into the budget, so it
    /// is named here rather than silently missing from the bar above.
    @ViewBuilder
    private var foreignSpendingNotice: some View {
        switch model.excludedForeignSpendingThisMonthResult(asOf: reportingDate) {
        case let .available(foreignSpending):
            ForEach(foreignSpending, id: \.currency) { money in
                HStack {
                    Text("plan.foreign_not_counted")
                    Spacer()
                    Text(formattedMoneyWithCurrencyCode(money))
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }
        case let .unavailable(issue):
            DerivedValueUnavailableView(issue: issue)
        }
    }

    @ViewBuilder
    var upcomingCard: some View {
        if let upcoming = nextScheduledTransaction {
            MoneyUpCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("dashboard.upcoming", systemImage: "calendar.badge.clock")
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
    }

    /// Insights has no tab of its own; Assets and History do, so neither is
    /// duplicated here as a shortcut.
    var insightsCard: some View {
        MoneyUpCard {
            NavigationLink {
                InsightsView()
            } label: {
                Label("dashboard.open_insights", systemImage: "chart.bar.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
        }
    }

    /// The one place Today still speaks about transactions: a book with none
    /// yet has nothing to steer, so it gets the first-run route instead of an
    /// empty copy of History.
    @ViewBuilder
    var firstRunCard: some View {
        if !model.journalRecentEntriesAreCurrent {
            MoneyUpCard {
                VStack(alignment: .leading, spacing: 12) {
                    DerivedValueUnavailableView(issue: .appNotReady)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("action.retry") {
                        model.retryUnavailableJournalProjection()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else if !model.hasJournalEntries {
            MoneyUpCard {
                VStack(alignment: .leading, spacing: 12) {
                    MoneyUpIllustration("MoneyUpMoneyWorld", role: .empty)
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
                }
            }
        }
    }

    var reportingDate: Date {
        reportingNow ?? model.currentDateForUserAction()
    }

    var reportingClockTaskID: String {
        "\(model.reportingCalendar.timeZone.identifier):\(reportingClockGeneration)"
    }

    func restartReportingClock() {
        reportingNow = model.currentDateForUserAction()
        reportingClockGeneration &+= 1
    }

    /// A sleeping foreground task is effectively free, is cancelled with the
    /// view, and is paired with the scene-phase refresh for suspended apps.
    /// Every Today calculation reads the resulting single reporting instant.
    @MainActor
    func refreshAtReportingDayBoundaries() async {
        while !Task.isCancelled {
            let now = model.currentDateForUserAction()
            reportingNow = now
            let scheduledOccurrences = model.scheduledTransactions.compactMap {
                $0.occurrence(onOrAfter: now, calendar: model.reportingCalendar)
            }
            guard let nextRefresh = DashboardReportingClockPolicy.nextRefresh(
                after: now,
                calendar: model.reportingCalendar,
                scheduledOccurrences: scheduledOccurrences
            ) else { return }
            let delay = max(nextRefresh.timeIntervalSince(now), 0.001)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }

    func budgetPaceKey(ratio: Double) -> LocalizedStringKey {
        if ratio > 1 { return "dashboard.budget_pace.over" }
        if ratio > monthElapsed + 0.05 { return "dashboard.budget_pace.ahead" }
        return "dashboard.budget_pace.within"
    }

    func budgetPaceSymbol(ratio: Double) -> String {
        if ratio > 1 { return "exclamationmark.triangle.fill" }
        if ratio > monthElapsed + 0.05 { return "gauge.with.dots.needle.67percent" }
        return "checkmark.circle.fill"
    }

    var quickActions: some View {
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

    var logButton: some View {
        Button {
            onOpenLog()
        } label: {
            Label("dashboard.log_money", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.moneyUpAction)
    }

    var planButton: some View {
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
