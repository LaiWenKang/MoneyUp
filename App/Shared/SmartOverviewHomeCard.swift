import SwiftUI

/// The same native surface renders in the extension and visual regression
/// tests. The shared snapshot is deliberately incapable of carrying amounts.
struct SmartOverviewHomeCard: View {
    let presentation: SmartOverviewWidgetPresentation
    let focus: SmartOverviewFocus
    let isMedium: Bool
    var accent: Color = .accentColor

    private var primary: SmartOverviewWidgetPresentation.Component { presentation.spotlight(for: focus) }
    private var isAccessible: Bool { presentation.homeDensity == .accessibility }

    var body: some View {
        VStack(alignment: .leading, spacing: isAccessible ? 6 : 10) {
            if !isAccessible {
                HStack {
                    Text("widget.brand_name").font(.caption2.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold))
                }.foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 16) {
                headline
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isMedium && !isAccessible {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(presentation.supportingComponents(for: focus).prefix(2)), id: \.self) { component in
                            metric(component)
                        }
                    }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title(primary), systemImage: symbol(primary))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                if !isAccessible, primary == .budget, case let .available(percentUsed) = presentation.budget {
                    HStack(spacing: 10) {
                        primaryValue.fixedSize(horizontal: true, vertical: false)
                        budgetDial(percentUsed)
                    }
                }
                primaryValue
            }
            if !isAccessible {
                Text(detail(primary))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var primaryValue: some View {
        Text(value(primary))
            .font(isAccessible ? .title3.bold() : .system(.largeTitle, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    private func budgetDial(_ percent: Int) -> some View {
        ZStack {
            Circle().stroke(accent.opacity(0.16), lineWidth: 5)
            Circle().trim(from: 0, to: min(max(CGFloat(percent) / 100, 0), 1))
                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: percent > 100 ? "exclamationmark" : "chart.pie.fill")
                .font(.caption).foregroundStyle(accent)
        }
        .frame(width: 36, height: 36).padding(3)
        .accessibilityHidden(true)
    }

    private func metric(_ component: SmartOverviewWidgetPresentation.Component) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title(component), systemImage: symbol(component))
                .font(.caption2).foregroundStyle(.secondary)
            Text(value(component)).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func title(_ component: SmartOverviewWidgetPresentation.Component) -> LocalizedStringKey {
        switch component {
        case .budget: isAccessible ? "widget.smart_budget" : "widget.focus.budget_used"
        case .review: "widget.smart_review"
        case .allowance: "widget.smart_allowance"
        case .commitment: isAccessible ? "widget.focus.due" : "widget.focus.next_payment"
        }
    }

    private func symbol(_ component: SmartOverviewWidgetPresentation.Component) -> String {
        switch component {
        case .budget: "chart.pie.fill"
        case .review: presentation.reviewCount == 0 ? "checkmark.circle" : "exclamationmark.magnifyingglass"
        case .allowance: "giftcard"
        case .commitment: "calendar.badge.clock"
        }
    }

    private func value(_ component: SmartOverviewWidgetPresentation.Component) -> String {
        switch component {
        case .budget:
            switch presentation.budget {
            case let .available(percentUsed): return "\(percentUsed)%"
            case .needsBudget: return AppLocalization.string("widget.smart_budget_needs")
            case .zeroBudget: return AppLocalization.string("widget.smart_budget_zero")
            case .negativeBudget: return AppLocalization.string("widget.smart_budget_negative")
            case .disabled, .stale: return "—"
            }
        case .review: return presentation.reviewCount.map { String($0) } ?? "—"
        case .allowance: return presentation.allowancePercentRemaining.map { "\($0)%" } ?? "—"
        case .commitment:
            if case .none = presentation.commitment { return AppLocalization.string("widget.smart_none") }
            switch presentation.commitmentDayDistance {
            case .today: return AppLocalization.string("widget.smart.today")
            case .oneDay: return AppLocalization.string("widget.focus.tomorrow")
            case let .days(days): return String(format: AppLocalization.string("widget.smart.days"), days)
            case .unavailable: return "—"
            }
        }
    }

    private func detail(_ component: SmartOverviewWidgetPresentation.Component) -> LocalizedStringKey {
        switch component {
        case .budget:
            if case let .available(percentUsed) = presentation.budget, percentUsed > 100 { return "widget.focus.over_limit" }
            return "widget.focus.monthly_plan"
        case .review: return presentation.reviewCount == 0 ? "widget.focus.review_clear" : "widget.focus.review_detail"
        case .allowance: return "widget.focus.allowance_detail"
        case .commitment: return "widget.focus.scheduled_detail"
        }
    }
}
