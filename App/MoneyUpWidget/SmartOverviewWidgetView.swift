import SwiftUI
import WidgetKit

struct SmartOverviewWidgetView: View {
    let presentation: SmartOverviewWidgetPresentation

    init(
        snapshot: BudgetWidgetSnapshot,
        insights: MoneyUpWidgetInsights?,
        family: WidgetFamily,
        homeDensity: MoneyUpWidgetHomeDensity = .standard
    ) {
        presentation = SmartOverviewWidgetPresentation.make(
            budget: snapshot,
            insights: insights,
            family: Self.presentationFamily(for: family),
            homeDensity: homeDensity
        )
    }

    @ViewBuilder
    var body: some View {
        switch presentation.family {
        case .systemSmall:
            systemSmall
        case .systemMedium:
            systemMedium
        case .accessoryInline:
            accessoryInline
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        }
    }

    private var showsBudgetRecoveryMessage: Bool {
        presentation.budget.requiresSettingsEnablement
            || presentation.budget.canRefreshByOpeningApp
    }

    private var reviewValue: String {
        presentation.reviewCount.map { String($0) } ?? "—"
    }

    private var allowanceValue: String {
        presentation.allowancePercentRemaining.map { "\($0)%" } ?? "—"
    }

    private var commitmentValue: String {
        switch presentation.commitmentDayDistance {
        case .unavailable:
            return "—"
        case .today:
            return AppLocalization.string("widget.smart.today")
        case .oneDay:
            return String(format: AppLocalization.string("widget.smart.days"), 1)
        case let .days(days):
            return String(format: AppLocalization.string("widget.smart.days"), days)
        }
    }

    private var reviewAccessibilityValue: String {
        presentation.reviewCount.map { String($0) }
            ?? AppLocalization.string("widget.smart_unavailable")
    }

    private var allowanceAccessibilityValue: String {
        presentation.allowancePercentRemaining.map { "\($0)%" }
            ?? AppLocalization.string("widget.smart_unavailable")
    }

    private var commitmentSummaryValue: String {
        switch presentation.commitment {
        case .unavailable:
            return "—"
        case .none:
            return AppLocalization.string("widget.smart_none")
        case let .active(count, _):
            return String(
                format: AppLocalization.string("widget.smart_commitment_summary"),
                count,
                commitmentValue
            )
        }
    }

    private var commitmentAccessibilityValue: String {
        switch presentation.commitment {
        case .unavailable:
            return AppLocalization.string("widget.smart_unavailable")
        case .none:
            return AppLocalization.string("widget.smart_no_commitments")
        case let .active(count, _):
            let nextDue: String
            switch presentation.commitmentDayDistance {
            case .unavailable:
                nextDue = AppLocalization.string("widget.smart_unavailable")
            case .today:
                nextDue = AppLocalization.string("widget.smart.today")
            case .oneDay:
                nextDue = AppLocalization.string("widget.smart.one_day")
            case let .days(days):
                nextDue = String(
                    format: AppLocalization.string("widget.smart.days_long"),
                    days
                )
            }
            return String(
                format: AppLocalization.string(
                    "widget.smart_commitment_accessibility"
                ),
                count,
                nextDue
            )
        }
    }

    private var budgetValue: String {
        switch presentation.budget {
        case .disabled:
            return AppLocalization.string("widget.smart_budget_disabled")
        case .needsBudget:
            return AppLocalization.string("widget.smart_budget_needs")
        case .zeroBudget:
            return AppLocalization.string("widget.smart_budget_zero")
        case .negativeBudget:
            return AppLocalization.string("widget.smart_budget_negative")
        case .stale:
            return AppLocalization.string("widget.smart_budget_stale")
        case let .available(percentUsed):
            return visiblePercentUsed(percentUsed)
        }
    }

    private var budgetSymbol: String {
        switch presentation.budget {
        case .disabled:
            return "eye.slash.fill"
        case .needsBudget:
            return "chart.pie"
        case .zeroBudget:
            return "nosign"
        case .negativeBudget:
            return "exclamationmark.triangle.fill"
        case .stale:
            return "arrow.clockwise.circle"
        case let .available(percentUsed):
            return percentUsed > 100
                ? "exclamationmark.triangle.fill"
                : "chart.pie.fill"
        }
    }

    private var budgetAccessibilityValue: String {
        switch presentation.budget {
        case .disabled:
            return AppLocalization.string("widget.smart_enable")
        case .needsBudget:
            return AppLocalization.string("widget.budget_needs_plan")
        case .zeroBudget:
            return AppLocalization.string("widget.budget_zero_plan")
        case .negativeBudget:
            return AppLocalization.string("widget.budget_negative_plan")
        case .stale:
            return AppLocalization.string("widget.smart_open_app")
        case let .available(percentUsed):
            let status = percentUsed > 100
                ? AppLocalization.string("widget.budget_over")
                : AppLocalization.string("widget.budget_on_plan")
            return String(
                format: AppLocalization.string("widget.budget_accessibility"),
                percentUsed,
                status
            )
        }
    }

    @ViewBuilder
    private var systemSmall: some View {
        if showsBudgetRecoveryMessage {
            unavailableBudgetMessage
        } else if presentation.homeDensity == .accessibility {
            systemSmallAccessibility
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WidgetBrandHeader()
                HStack(spacing: 5) {
                    Image(systemName: budgetSymbol).foregroundStyle(.tint)
                    Text("widget.smart_budget")
                    Spacer(minLength: 4)
                    Text(budgetValue)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("widget.smart_budget")
                .accessibilityValue(budgetAccessibilityValue)
                Divider()
                HStack(alignment: .top, spacing: 5) {
                    compactInsight(
                        value: reviewValue,
                        label: "widget.smart_review_short",
                        symbol: "exclamationmark.magnifyingglass",
                        accessibilityValue: reviewAccessibilityValue
                    )
                    compactInsight(
                        value: allowanceValue,
                        label: "widget.smart_allowance_short",
                        symbol: "giftcard",
                        accessibilityValue: allowanceAccessibilityValue
                    )
                    compactInsight(
                        value: commitmentSummaryValue,
                        label: "widget.smart_commitment_short",
                        symbol: "calendar.badge.clock",
                        accessibilityValue: commitmentAccessibilityValue
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var systemMedium: some View {
        if showsBudgetRecoveryMessage {
            unavailableBudgetMessage
        } else if presentation.homeDensity == .accessibility {
            systemMediumAccessibility
        } else {
            VStack(alignment: .leading, spacing: 9) {
                WidgetBrandHeader()
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        mediumInsightTile(
                            value: budgetValue,
                            label: "widget.smart_budget",
                            symbol: budgetSymbol,
                            accessibilityValue: budgetAccessibilityValue
                        )
                        mediumInsightTile(
                            value: reviewValue,
                            label: "widget.smart_review",
                            symbol: "exclamationmark.magnifyingglass",
                            accessibilityValue: reviewAccessibilityValue
                        )
                    }
                    HStack(spacing: 6) {
                        mediumInsightTile(
                            value: allowanceValue,
                            label: "widget.smart_allowance",
                            symbol: "giftcard",
                            accessibilityValue: allowanceAccessibilityValue
                        )
                        mediumInsightTile(
                            value: commitmentSummaryValue,
                            label: "widget.smart_commitments_next",
                            symbol: "calendar.badge.clock",
                            accessibilityValue: commitmentAccessibilityValue
                        )
                    }
                }
            }
        }
    }

    private var systemSmallAccessibility: some View {
        Label {
            Text(budgetValue)
                .font(.body.weight(.bold))
        } icon: {
            Image(systemName: budgetSymbol)
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("widget.smart_budget")
        .accessibilityValue(budgetAccessibilityValue)
    }

    private var systemMediumAccessibility: some View {
        HStack(alignment: .center, spacing: 12) {
            accessibilityMetric(
                value: budgetValue,
                label: "widget.smart_budget",
                symbol: budgetSymbol,
                accessibilityValue: budgetAccessibilityValue
            )
            if presentation.components.contains(.review) {
                accessibilityMetric(
                    value: reviewValue,
                    label: "widget.smart_review",
                    symbol: "exclamationmark.magnifyingglass",
                    accessibilityValue: reviewAccessibilityValue
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var accessoryInline: some View {
        if presentation.budget.requiresSettingsEnablement {
            Label("widget.smart_enable_short", systemImage: "eye.slash.fill")
        } else if presentation.budget.canRefreshByOpeningApp {
            Label("widget.smart_refresh_short", systemImage: "arrow.clockwise")
        } else {
            Label {
                Text(String(
                    format: AppLocalization.string("widget.smart_inline_budget_review"),
                    budgetValue,
                    reviewValue
                ))
            } icon: {
                Image(systemName: budgetSymbol)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("widget.smart_overview")
            .accessibilityValue(String(
                format: AppLocalization.string("widget.smart_inline_accessibility"),
                budgetAccessibilityValue,
                reviewAccessibilityValue
            ))
        }
    }

    @ViewBuilder
    private var accessoryCircular: some View {
        switch presentation.budget {
        case .disabled:
            Image(systemName: "eye.slash.fill")
                .widgetAccentable()
                .accessibilityLabel("widget.smart_enable_short")
        case .stale:
            Image(systemName: "arrow.clockwise")
                .widgetAccentable()
                .accessibilityLabel("widget.smart_open_app")
        case let .available(percentUsed):
            Gauge(value: min(Double(percentUsed), 100), in: 0...100) {
                Text("widget.smart_budget")
            } currentValueLabel: {
                Text("\(percentUsed)%")
                    .font(.caption2.monospacedDigit().weight(.bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityLabel("widget.smart_budget")
            .accessibilityValue(budgetAccessibilityValue)
        case .needsBudget, .zeroBudget, .negativeBudget:
            Image(systemName: budgetSymbol)
                .font(.headline)
                .widgetAccentable()
                .accessibilityLabel("widget.smart_budget")
                .accessibilityValue(budgetAccessibilityValue)
        }
    }

    @ViewBuilder
    private var accessoryRectangular: some View {
        if showsBudgetRecoveryMessage {
            unavailableBudgetMessage
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Label("widget.smart_budget", systemImage: budgetSymbol)
                        .font(.caption2)
                    Text(budgetValue)
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Label(reviewValue, systemImage: "exclamationmark.magnifyingglass")
                        .font(.caption.weight(.semibold))
                    Label(commitmentSummaryValue, systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("widget.smart_overview")
            .accessibilityValue(String(
                format: AppLocalization.string("widget.smart_accessibility_summary"),
                budgetAccessibilityValue,
                reviewAccessibilityValue,
                commitmentAccessibilityValue
            ))
        }
    }

    @ViewBuilder
    private var unavailableBudgetMessage: some View {
        let isDisabled = presentation.budget.requiresSettingsEnablement
        let detail: LocalizedStringKey = isDisabled
            ? "widget.smart_enable"
            : "widget.smart_open_app"
        let compactDetail: LocalizedStringKey = isDisabled
            ? "widget.smart_enable_short"
            : "widget.smart_refresh_short"
        let symbol = isDisabled ? "eye.slash.fill" : "arrow.clockwise.circle"

        switch presentation.family {
        case .systemSmall:
            if presentation.homeDensity == .accessibility {
                Label(detail, systemImage: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                    .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetBrandHeader()
                    Spacer(minLength: 0)
                    Label(detail, systemImage: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        case .systemMedium:
            if presentation.homeDensity == .accessibility {
                Label(detail, systemImage: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                    .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("widget.smart_overview").font(.headline)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        case .accessoryInline:
            Label(compactDetail, systemImage: symbol)
        case .accessoryCircular:
            Image(systemName: symbol)
                .widgetAccentable()
                .accessibilityLabel(compactDetail)
        case .accessoryRectangular:
            HStack(spacing: 7) {
                Image(systemName: symbol).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("widget.smart_overview").font(.caption2.weight(.semibold))
                    Text(compactDetail).font(.caption).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func mediumInsightTile(
        value: String,
        label: LocalizedStringKey,
        symbol: String,
        accessibilityValue: String? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.moneyUpSoftGreen.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? value)
    }

    private func compactInsight(
        value: String,
        label: LocalizedStringKey,
        symbol: String,
        accessibilityValue: String
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private func accessibilityMetric(
        value: String,
        label: LocalizedStringKey,
        symbol: String,
        accessibilityValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private func visiblePercentUsed(_ percent: Int) -> String {
        String(
            format: AppLocalization.string("widget.budget_used_format"),
            percent
        )
    }

    private static func presentationFamily(
        for family: WidgetFamily
    ) -> SmartOverviewWidgetPresentation.Family {
        switch family {
        case .systemSmall:
            return .systemSmall
        case .systemMedium:
            return .systemMedium
        case .accessoryInline:
            return .accessoryInline
        case .accessoryCircular:
            return .accessoryCircular
        case .accessoryRectangular:
            return .accessoryRectangular
        default:
            return .systemSmall
        }
    }
}
