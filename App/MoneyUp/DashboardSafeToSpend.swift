import MoneyUpCore
import SwiftUI

/// The whole-book discretionary figure.
///
/// It leads Today only while the board has no pinned categories; once the
/// user has named the categories they steer by, this collapses to a single
/// line that keeps the number and its arithmetic one tap away.
extension DashboardView {
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
                            format: AppLocalization.string("dashboard.flexible_today.classify_title"),
                            count
                        ),
                        detail: "dashboard.flexible_today.classify_detail"
                    )
                case .available(.needsFlexibleBudget):
                    setupGuidance(
                        title: AppLocalization.string("dashboard.flexible_today.needs_flexible"),
                        detail: "dashboard.flexible_today.needs_flexible_detail"
                    )
                case let .unavailable(issue):
                    Label("dashboard.safe_to_spend", systemImage: "sun.max.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    DerivedValueUnavailableView(issue: issue, prominent: true)
                }
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
                .moneyUpFinancialValue(.hero)
                .foregroundStyle(
                    breakdown.availableForRemainingPeriod.amount < .zero
                        ? Color.red
                        : Color.primary
                )
            Text("dashboard.safe_to_spend.per_day")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label(
                String(
                    format: AppLocalization.string("dashboard.safe_to_spend.weekly_format"),
                    formattedMoney(breakdown.amountForNextSevenDays),
                    min(7, breakdown.remainingDayCount)
                ),
                systemImage: "calendar.day.timeline.left"
            )
            .font(.footnote.weight(.semibold))
            if breakdown.availableForRemainingPeriod.amount < .zero {
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

    /// The collapsed form used once pinned categories lead the board. It keeps
    /// the figure, its currency, and the route to the arithmetic, and drops the
    /// illustration and the setup copy that the full hero carries.
    var safeToSpendSummary: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 10) {
                switch model.flexibleTodayResult(asOf: reportingDate) {
                case let .available(.available(breakdown)):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label("dashboard.safe_to_spend", systemImage: "sun.max.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(formattedMoney(breakdown.amountPerDay))
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(
                                    breakdown.availableForRemainingPeriod.amount < .zero
                                        ? Color.red
                                        : Color.primary
                                )
                            Text("dashboard.safe_to_spend.per_day")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    Button {
                        isShowingFlexibleTodayBreakdown = true
                    } label: {
                        Label(
                            "dashboard.safe_to_spend.show_math",
                            systemImage: "function"
                        )
                        .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                case .available:
                    Button {
                        onOpenPlan()
                    } label: {
                        Label(
                            "dashboard.safe_to_spend.setup_pending",
                            systemImage: "checklist"
                        )
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                case let .unavailable(issue):
                    DerivedValueUnavailableView(issue: issue)
                }
            }
        }
    }
}
