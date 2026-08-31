import MoneyUpCore
import SwiftUI

extension DashboardView {
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    safeToSpendHero

                    MoneyUpCard {
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

                    MoneyUpCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dashboard.monthly_budget")
                                .font(.headline)
                            switch budgetSummary {
                            case let .available(.some(summary)):
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
                                Text(
                                    "\(formattedMoney(summary.spent)) / \(formattedMoney(summary.limit))"
                                )
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
                            switch model.excludedForeignSpendingThisMonthResult(
                                asOf: reportingDate
                            ) {
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
                        MoneyUpCard {
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

                    MoneyUpCard {
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

                            Button {
                                onOpenAssets()
                            } label: {
                                Label("dashboard.open_assets", systemImage: "wallet.bifold.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 6)
                        }
                    }

                    MoneyUpCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dashboard.recent")
                                .font(.headline)
                            if !model.journalRecentEntriesAreCurrent {
                                DerivedValueUnavailableView(issue: .appNotReady)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("action.retry") {
                                    model.retryUnavailableJournalProjection()
                                }
                                .buttonStyle(.bordered)
                            } else if !model.hasJournalEntries {
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

                    MoneyUpCard {
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
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
        .task(id: reportingClockTaskID) {
            await refreshAtReportingDayBoundaries()
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

    var safeToSpendHero: some View {
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
                switch model.flexibleTodayResult(asOf: reportingDate) {
                case let .available(.available(breakdown)):
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 12) {
                                heroIllustration
                                flexibleTodayCopy(breakdown)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 12) {
                                flexibleTodayCopy(breakdown)
                                heroIllustration
                            }
                        }
                    }

                    Button {
                        isShowingFlexibleTodayBreakdown = true
                    } label: {
                        Label(
                            "dashboard.safe_to_spend.show_math",
                            systemImage: "function"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                case .available(.needsBudget):
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
                case let .available(.needsClassification(count)):
                    setupGuidance(
                        title: String(
                            format: String(localized: "dashboard.flexible_today.classify_title"),
                            count
                        ),
                        detail: "dashboard.flexible_today.classify_detail"
                    )
                case .available(.needsFlexibleBudget):
                    setupGuidance(
                        title: String(localized: "dashboard.flexible_today.needs_flexible"),
                        detail: "dashboard.flexible_today.needs_flexible_detail"
                    )
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

    var heroIllustration: some View {
        MoneyUpIllustration("MoneyUpMoneyWorld", role: .hero)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
    }

    @ViewBuilder
    func setupGuidance(
        title: String,
        detail: LocalizedStringKey
    ) -> some View {
        Label("dashboard.safe_to_spend", systemImage: "rectangle.3.group.fill")
            .font(.headline)
            .foregroundStyle(.tint)
        Text(title)
            .font(.title3.weight(.semibold))
        Text(detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        Button {
            onOpenPlan()
        } label: {
            Label("dashboard.flexible_today.review_plan", systemImage: "checklist")
        }
        .buttonStyle(.borderedProminent)
        .tint(.moneyUpAction)
    }

    func flexibleTodayCopy(
        _ breakdown: FlexibleTodayBreakdown
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
