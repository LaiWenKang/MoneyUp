import Charts
import MoneyUpCore
import SwiftUI

/// A read-only what-if view. It never mutates the ledger, the budget, or
/// any report; every figure is recomputed from the live plan plus the
/// amounts typed here.
struct BudgetSimulatorView: View {
    private enum Field: Hashable {
        case spending
        case income
    }

    private struct ChartPoint: Identifiable {
        let id: String
        let label: String
        let money: Money

        var amount: Double {
            NSDecimalNumber(decimal: money.amount).doubleValue
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.appReportingSnapshot) private var sharedReportingSnapshot
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @AppStorage(MoneyAmountPrivacy.storageKey)
    private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @State private var additionalSpendingText = ""
    @State private var additionalIncomeText = ""
    @FocusState private var focusedField: Field?

    private var reportingSnapshot: AppReportingSnapshot {
        sharedReportingSnapshot
            ?? AppReportingSnapshot(
                instant: model.currentDateForUserAction(),
                calendar: model.reportingCalendar
            )
    }

    var body: some View {
        let _ = hidesAmounts
        let snapshot = reportingSnapshot
        return ScrollView {
            LazyVStack(spacing: 16) {
                MoneyUpCard {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            simulatorIntroduction
                            MoneyUpIllustration("MoneyUpScenarioStudio", role: .inline)
                        }
                        VStack(spacing: 12) {
                            MoneyUpIllustration("MoneyUpScenarioStudio", role: .empty)
                            simulatorIntroduction
                        }
                    }
                }

                switch (
                    model.budgetPlanSummaryThisMonthResult(
                        asOf: snapshot.instant
                    ),
                    model.reportResult(
                        for: .thisMonth,
                        asOf: snapshot.instant
                    )
                ) {
                case let (.available(.some(summary)), .available(report)):
                    simulator(
                        summary: summary,
                        report: report,
                        monthElapsed: snapshot.monthElapsed
                    )
                case (.available(.none), _):
                    MoneyUpCard {
                        ContentUnavailableView(
                            "simulator.needs_budget",
                            systemImage: "chart.pie",
                            description: Text("simulator.needs_budget_detail")
                        )
                    }
                case let (.unavailable(issue), _), let (_, .unavailable(issue)):
                    MoneyUpCard {
                        DerivedValueUnavailableView(issue: issue, prominent: true)
                    }
                }
            }
            .padding()
        }
        .background { MoneyUpBackdrop() }
        .navigationTitle("simulator.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MoneyUpKeyboardDoneToolbar()
            ToolbarItem(placement: .primaryAction) {
                MoneyUpAmountPrivacyButton()
            }
        }
    }

    private var simulatorIntroduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("simulator.preview_only", systemImage: "eye.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text("simulator.title")
                .font(.title2.bold())
            Text("simulator.detail")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func simulator(
        summary: BudgetPlanSummary,
        report: PeriodReport,
        monthElapsed: Double
    ) -> some View {
        let currency = summary.limit.currency
        let additionalSpending = parsedAmount(
            additionalSpendingText,
            currency: currency
        )
        let additionalIncome = parsedAmount(
            additionalIncomeText,
            currency: currency
        )

        MoneyUpCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("simulator.adjust", systemImage: "slider.horizontal.3")
                    .font(.headline)

                scenarioField(
                    "simulator.additional_spending",
                    text: $additionalSpendingText,
                    currency: currency,
                    field: .spending,
                    validationMessage: additionalSpending == nil
                        ? AppLocalization.string("simulator.invalid_amount")
                        : nil
                )

                Divider()

                scenarioField(
                    "simulator.additional_income",
                    text: $additionalIncomeText,
                    currency: currency,
                    field: .income,
                    validationMessage: additionalIncome == nil
                        ? AppLocalization.string("simulator.invalid_amount")
                        : nil
                )

                Button("simulator.reset") {
                    additionalSpendingText = ""
                    additionalIncomeText = ""
                }
                .font(.subheadline.weight(.semibold))
                .disabled(additionalSpendingText.isEmpty && additionalIncomeText.isEmpty)
            }
        }

        if let additionalSpending, let additionalIncome {
            if let forecast = try? FinanceCalculator.budgetScenario(
                currentSpent: summary.spent,
                budgetLimit: summary.limit,
                currentIncome: report.baseFlow.income,
                additionalSpending: additionalSpending,
                additionalIncome: additionalIncome
            ) {
                forecastCards(forecast, monthElapsed: monthElapsed)
            } else {
                MoneyUpCard {
                    Text("simulator.unavailable")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func scenarioField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        currency: CurrencyCode,
        field: Field,
        validationMessage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(currency.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            TextField("simulator.amount_placeholder", text: text)
                .moneyAmountKeyboard(currency: currency)
                .focused($focusedField, equals: field)
                .textFieldStyle(.roundedBorder)
                .moneyUpFieldValidation(validationMessage)
                .moneyUpPrivateAmountInput(
                    masked: hidesAmounts
                        && focusedField != field
                        && !text.wrappedValue.isEmpty,
                    accessibilityLabel: Text(title)
                ) {
                    focusedField = field
                }
            if let validationMessage {
                MoneyUpFieldError(message: validationMessage)
            }
        }
    }

    @ViewBuilder
    private func forecastCards(
        _ forecast: BudgetScenarioForecast,
        monthElapsed: Double
    ) -> some View {
        let points = [
            ChartPoint(
                id: "current",
                label: AppLocalization.string("simulator.current"),
                money: forecast.currentSpent
            ),
            ChartPoint(
                id: "projected",
                label: AppLocalization.string("simulator.projected"),
                money: forecast.projectedSpent
            )
        ]
        let limit = NSDecimalNumber(decimal: forecast.budgetLimit.amount).doubleValue
        let isOver = forecast.projectedRemaining.amount < .zero
        let budgetUsage = budgetUsageResult(forecast)

        forecastSpendingCard(
            forecast,
            points: points,
            limit: limit,
            isOver: isOver,
            budgetUsage: budgetUsage,
            monthElapsed: monthElapsed
        )
        forecastSummaryCard(forecast, isOver: isOver)
    }

    private func forecastSpendingCard(
        _ forecast: BudgetScenarioForecast,
        points: [ChartPoint],
        limit: Double,
        isOver: Bool,
        budgetUsage: DerivedValue<Decimal?>,
        monthElapsed: Double
    ) -> some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("simulator.spending_chart", systemImage: "chart.bar.xaxis")
                    .font(.headline)

                Chart {
                    ForEach(points) { point in
                        BarMark(
                            x: .value(
                                AppLocalization.string("chart.dimension.scenario"),
                                point.label
                            ),
                            y: .value(
                                AppLocalization.string("chart.dimension.amount"),
                                point.amount
                            )
                        )
                        .foregroundStyle(
                            point.id == "current"
                                ? Color.secondary
                                : (isOver ? Color.red : Color.accentColor)
                        )
                        .annotation(position: .top) {
                            Text(formattedMoney(point.money))
                                .font(.caption2.monospacedDigit())
                        }
                        .accessibilityLabel(point.label)
                        .accessibilityValue(accessibleFormattedMoney(point.money))
                    }

                    RuleMark(
                        y: .value(
                            AppLocalization.string("chart.dimension.budget"),
                            limit
                        )
                    )
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("simulator.budget_line")
                                .font(.caption2.weight(.semibold))
                        }
                        .accessibilityLabel("simulator.budget_line")
                        .accessibilityValue(
                            accessibleFormattedMoney(forecast.budgetLimit)
                        )
                }
                .frame(height: 240)
                .chartLegend(.hidden)
                .chartYAxis(hidesAmounts ? .hidden : .automatic)
                .accessibilityLabel(Text("simulator.chart_accessibility"))
                .accessibilityHidden(hidesAmounts)
                .animation(
                    MoneyUpMotion.animation(
                        for: .stateChange,
                        reduceMotion: reduceMotion
                    ),
                    value: forecast.projectedSpent.amount
                )

                if case let .available(.some(ratio)) = budgetUsage {
                    MoneyUpPaceBar(
                        ratio: NSDecimalNumber(decimal: ratio).doubleValue,
                        elapsed: monthElapsed
                    )
                } else if case let .unavailable(issue) = budgetUsage {
                    DerivedValueUnavailableView(issue: issue)
                }
            }
        }
    }

    private func forecastSummaryCard(
        _ forecast: BudgetScenarioForecast,
        isOver: Bool
    ) -> some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(
                        isOver
                            ? LocalizedStringKey("simulator.projected_over")
                            : LocalizedStringKey("simulator.projected_left")
                    )
                } icon: {
                    Image(
                        systemName: isOver
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                }
                .font(.headline)
                .foregroundStyle(isOver ? Color.red : Color.primary)

                Text(
                    formattedMoney(
                        isOver
                            ? forecast.projectedRemaining.negated
                            : forecast.projectedRemaining
                    )
                )
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()

                Divider()

                LabeledContent("simulator.projected_income") {
                    Text(formattedMoney(forecast.projectedIncome))
                        .monospacedDigit()
                }
                LabeledContent("simulator.projected_spending") {
                    Text(formattedMoney(forecast.projectedSpent))
                        .monospacedDigit()
                }
                LabeledContent("simulator.projected_net") {
                    Text(formattedMoney(forecast.projectedNet))
                        .monospacedDigit()
                }

                Text("simulator.no_changes_saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func budgetUsageResult(
        _ forecast: BudgetScenarioForecast
    ) -> DerivedValue<Decimal?> {
        do {
            return .available(try forecast.budgetUsage())
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "budget-scenario-usage",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    private func parsedAmount(
        _ text: String,
        currency: CurrencyCode
    ) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .zero }
        guard let amount = decimalAmount(from: trimmed),
              amount >= .zero,
              currency.supports(amount) else { return nil }
        return amount
    }
}
