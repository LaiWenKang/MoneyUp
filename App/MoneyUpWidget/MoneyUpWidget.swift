import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct MoneyUpWidgetBundle: WidgetBundle {
    var body: some Widget {
        MoneyUpQuickActionsWidget()
        MoneyUpQuickLogControl()
    }
}

enum MoneyUpWidgetContent: String, AppEnum, CaseIterable, Identifiable, Sendable {
    case quickAction
    case budgetStatus
    case smartOverview

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        "widget.configuration.content_type"
    static let caseDisplayRepresentations: [MoneyUpWidgetContent: DisplayRepresentation] = [
        .quickAction: "widget.content.quick_actions",
        .budgetStatus: "widget.content.budget_status",
        .smartOverview: "widget.content.smart_overview"
    ]

    var id: String { rawValue }
}

struct MoneyUpWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.configuration.title"
    static let description = IntentDescription("widget.configuration.description")

    @Parameter(
        title: "widget.configuration.content",
        default: MoneyUpWidgetContent.quickAction
    )
    var content: MoneyUpWidgetContent

    @Parameter(
        title: "widget.configuration.default_action",
        default: MoneyUpQuickAction.expense
    )
    var defaultAction: MoneyUpQuickAction
}

private struct MoneyUpWidgetEntry: TimelineEntry {
    let date: Date
    let content: MoneyUpWidgetContent
    let action: MoneyUpQuickAction
    let budgetSnapshot: BudgetWidgetSnapshot
    let insights: MoneyUpWidgetInsights?
}

private struct MoneyUpWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MoneyUpWidgetEntry {
        MoneyUpWidgetEntry(
            date: Date(),
            content: .quickAction,
            action: .expense,
            budgetSnapshot: .disabled,
            insights: nil
        )
    }

    func snapshot(
        for configuration: MoneyUpWidgetConfigurationIntent,
        in context: Context
    ) async -> MoneyUpWidgetEntry {
        makeEntry(for: configuration)
    }

    func timeline(
        for configuration: MoneyUpWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<MoneyUpWidgetEntry> {
        let entry = makeEntry(for: configuration)
        let policy: TimelineReloadPolicy
        var validUntil: Date?
        switch entry.budgetSnapshot {
        case let .available(_, expiry), let .needsBudget(expiry):
            validUntil = expiry
        case .disabled, .stale:
            validUntil = nil
        }
        if entry.content == .smartOverview,
           let expiry = entry.insights?.validUntil,
           expiry > entry.date {
            validUntil = min(validUntil ?? expiry, expiry)
        }
        if let validUntil, validUntil > entry.date {
            policy = .after(validUntil)
        } else {
            policy = .never
        }
        return Timeline(entries: [entry], policy: policy)
    }

    private func makeEntry(
        for configuration: MoneyUpWidgetConfigurationIntent
    ) -> MoneyUpWidgetEntry {
        let store = BudgetWidgetSnapshotStore()
        return MoneyUpWidgetEntry(
            date: Date(),
            content: configuration.content,
            action: configuration.defaultAction,
            budgetSnapshot: store.read(),
            insights: store.readInsights()
        )
    }
}

private struct MoneyUpWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MoneyUpWidgetEntry

    var body: some View {
        Group {
            if entry.content == .budgetStatus {
                BudgetStatusWidgetView(
                    snapshot: entry.budgetSnapshot,
                    family: family
                )
            } else if entry.content == .smartOverview {
                SmartOverviewWidgetView(insights: entry.insights, family: family)
            } else {
                switch family {
                case .systemMedium:
                    ZStack {
                        WidgetAmbientGraphic()
                        MediumQuickActionsView(preferredAction: entry.action)
                    }
                case .accessoryCircular:
                    AccessoryCircularActionView(action: entry.action)
                case .accessoryRectangular:
                    AccessoryRectangularActionView(action: entry.action)
                case .accessoryInline:
                    AccessoryInlineActionView(action: entry.action)
                default:
                    ZStack {
                        WidgetAmbientGraphic()
                        SmallQuickActionView(action: entry.action)
                    }
                }
            }
        }
        .environment(\.locale, AppLanguagePreference.current.locale)
        .containerBackground(Color.moneyUpWidgetBackground, for: .widget)
        .tint(.moneyUpSoftGreen)
    }
}

private struct SmartOverviewWidgetView: View {
    let insights: MoneyUpWidgetInsights?
    let family: WidgetFamily

    var body: some View {
        guard let insights else {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    WidgetBrandHeader()
                    Spacer()
                    Label("widget.smart_open_app", systemImage: "arrow.clockwise.circle")
                        .font(.caption.weight(.semibold))
                }
            )
        }
        if family == .accessoryInline {
            return AnyView(
                Label {
                    Text(
                        String(
                            format: AppLocalization.string("widget.smart_inline"),
                            insights.reviewCount,
                            insights.activeCommitmentCount
                        )
                    )
                } icon: {
                    Image(systemName: "sparkles")
                }
            )
        }
        if family == .accessoryCircular {
            return AnyView(
                VStack(spacing: 1) {
                    Image(systemName: "sparkles")
                    Text("\(insights.reviewCount)").font(.caption.bold())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("widget.smart_review")
            )
        }
        return AnyView(
            VStack(alignment: .leading, spacing: family == .systemMedium ? 10 : 7) {
                WidgetBrandHeader()
                Label("widget.smart_overview", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if family == .systemMedium {
                    HStack(spacing: 8) {
                        insightTile(
                            value: "\(insights.reviewCount)",
                            label: "widget.smart_review",
                            symbol: "exclamationmark.magnifyingglass"
                        )
                        insightTile(
                            value: insights.allowancePercentRemaining.map { "\($0)%" } ?? "—",
                            label: "widget.smart_allowance",
                            symbol: "giftcard"
                        )
                        insightTile(
                            value: nextCommitmentValue(insights.nextCommitment),
                            label: "widget.smart_upcoming",
                            symbol: "calendar.badge.clock"
                        )
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(insights.reviewCount)")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .monospacedDigit()
                        Text("widget.smart_review").font(.caption)
                    }
                    Divider()
                    HStack {
                        Label(
                            insights.allowancePercentRemaining.map { "\($0)%" } ?? "—",
                            systemImage: "giftcard"
                        )
                        Spacer()
                        Label(
                            nextCommitmentValue(insights.nextCommitment),
                            systemImage: "calendar.badge.clock"
                        )
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .accessibilityElement(children: .combine)
        )
    }

    private func insightTile(
        value: String,
        label: LocalizedStringKey,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.moneyUpSoftGreen.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func nextCommitmentValue(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = max(Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0, 0)
        if days == 0 { return AppLocalization.string("widget.smart.today") }
        return String(format: AppLocalization.string("widget.smart.days"), days)
    }
}

private struct BudgetStatusWidgetView: View {
    let snapshot: BudgetWidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        switch snapshot {
        case .disabled:
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_enable",
                systemImage: "eye.slash.fill"
            )
        case .needsBudget(_):
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_needs_plan",
                systemImage: "chart.pie"
            )
        case .stale:
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_stale",
                systemImage: "arrow.clockwise.circle"
            )
        case let .available(percentUsed, _):
            availableStatus(percentUsed: percentUsed)
        }
    }

    @ViewBuilder
    private func availableStatus(percentUsed: Int) -> some View {
        let isOver = percentUsed > 100
        switch family {
        case .accessoryCircular:
            Gauge(value: min(Double(percentUsed), 100), in: 0...100) {
                Text("widget.budget_status")
            } currentValueLabel: {
                Text("\(percentUsed)%")
                    .font(.caption2.monospacedDigit().weight(.bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityLabel("widget.budget_status")
            .accessibilityValue(percentAccessibility(percentUsed, isOver: isOver))
        case .accessoryInline:
            Label {
                Text(visiblePercentUsed(percentUsed))
            } icon: {
                Image(systemName: isOver ? "exclamationmark.triangle.fill" : "chart.pie.fill")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("widget.budget_status")
            .accessibilityValue(percentAccessibility(percentUsed, isOver: isOver))
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: isOver ? "exclamationmark.triangle.fill" : "chart.pie.fill")
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("widget.budget_status").font(.caption2)
                    Text(visiblePercentUsed(percentUsed))
                        .font(.headline.monospacedDigit())
                    Text(
                        isOver
                            ? LocalizedStringKey("widget.budget_over")
                            : LocalizedStringKey("widget.budget_on_plan")
                    )
                        .font(.caption2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("widget.budget_status")
            .accessibilityValue(percentAccessibility(percentUsed, isOver: isOver))
        default:
            VStack(alignment: .leading, spacing: 9) {
                WidgetBrandHeader()
                Spacer(minLength: 0)
                Label {
                    Text(
                        isOver
                            ? LocalizedStringKey("widget.budget_over")
                            : LocalizedStringKey("widget.budget_on_plan")
                    )
                } icon: {
                    Image(
                        systemName: isOver
                            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                }
                .font(.caption.weight(.semibold))
                Text(visiblePercentUsed(percentUsed))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                ProgressView(value: min(Double(percentUsed), 100), total: 100)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("widget.budget_status")
            .accessibilityValue(percentAccessibility(percentUsed, isOver: isOver))
        }
    }

    @ViewBuilder
    private func statusMessage(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        if family == .accessoryInline {
            Label(detail, systemImage: systemImage)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemMedium ? 3 : 2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func percentAccessibility(_ percent: Int, isOver: Bool) -> String {
        let status = isOver
            ? AppLocalization.string("widget.budget_over")
            : AppLocalization.string("widget.budget_on_plan")
        return String(
            format: AppLocalization.string("widget.budget_accessibility"),
            percent,
            status
        )
    }

    private func visiblePercentUsed(_ percent: Int) -> String {
        String(
            format: AppLocalization.string("widget.budget_used_format"),
            percent
        )
    }
}

private struct SmallQuickActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        Button(intent: OpenQuickLogIntent(action: action)) {
            VStack(alignment: .leading, spacing: 8) {
                WidgetBrandHeader()

                Spacer(minLength: 0)

                WidgetActionGlyph(action: action, size: 48)
                    .accessibilityHidden(true)

                Text(action.titleKey)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if action.requiresUnlock {
                    Label("platform_action.unlock_required", systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(action.accessibilityHintKey)
    }
}

private struct MediumQuickActionsView: View {
    let preferredAction: MoneyUpQuickAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                WidgetBrandHeader()
                Spacer(minLength: 0)
                Text("widget.quick_actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(
                    MoneyUpQuickAction.mediumActions(preferred: preferredAction)
                ) { action in
                    Button(intent: OpenQuickLogIntent(action: action)) {
                        VStack(spacing: 7) {
                            WidgetActionGlyph(action: action, size: 38)
                            Text(action.titleKey)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            Color.moneyUpSoftGreen.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.moneyUpSoftGreen.opacity(0.15), lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(action.accessibilityHintKey)
                }
            }
        }
    }
}

private struct AccessoryCircularActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        Button(intent: OpenQuickLogIntent(action: action)) {
            ZStack {
                AccessoryWidgetBackground()
                Image("MoneyUpBrandMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.secondary.opacity(0.32))
                    .padding(7)
                Image(systemName: action.systemImage)
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.titleKey)
        .accessibilityHint(action.accessibilityHintKey)
    }
}

private struct AccessoryRectangularActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        Button(intent: OpenQuickLogIntent(action: action)) {
            HStack(spacing: 8) {
                ZStack {
                    Image("MoneyUpBrandMark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .opacity(0.28)
                    Image(systemName: action.systemImage)
                        .font(.subheadline.weight(.bold))
                }
                .widgetAccentable()
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("widget.title")
                        .font(.caption2.weight(.semibold))
                    Text(action.titleKey)
                        .font(.headline)
                        .lineLimit(1)
                    if action.requiresUnlock {
                        Label("platform_action.unlock_required", systemImage: "lock.fill")
                            .font(.caption2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(action.accessibilityHintKey)
    }
}

private struct WidgetBrandHeader: View {
    var body: some View {
        HStack(spacing: 7) {
            Image("MoneyUpBrandMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("widget.title")
                .font(.headline)
            Image(systemName: "lock.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("widget.private")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WidgetActionGlyph: View {
    let action: MoneyUpQuickAction
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.moneyUpAction.opacity(0.22))
                .offset(y: 3)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.moneyUpAction, Color.moneyUpActionDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(2)
            Circle()
                .stroke(Color.white.opacity(0.34), lineWidth: 1)
                .padding(3)
            Image(systemName: action.systemImage)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
            if action.requiresUnlock {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.18, weight: .bold))
                    .foregroundStyle(Color.moneyUpAction)
                    .padding(4)
                    .background(.white, in: Circle())
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A decorative, data-free diagram. It adds visual depth without exposing a
/// balance, payee, account, holding, or even an invented percentage.
private struct WidgetAmbientGraphic: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.moneyUpSoftGreen.opacity(0.12))
                    .frame(width: proxy.size.width * 0.72)
                    .offset(x: proxy.size.width * 0.24, y: -proxy.size.height * 0.38)

                Image("MoneyUpBrandMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.moneyUpSoftGreen.opacity(0.075))
                    .frame(width: min(proxy.size.width, proxy.size.height) * 0.78)
                    .offset(x: proxy.size.width * 0.08, y: proxy.size.height * 0.34)

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach([0.36, 0.56, 0.82], id: \.self) { fraction in
                        Capsule()
                            .fill(Color.moneyUpSoftGreen.opacity(0.10))
                            .frame(width: 7, height: proxy.size.height * fraction * 0.34)
                    }
                }
                .padding(.trailing, 4)
                .padding(.top, proxy.size.height * 0.50)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AccessoryInlineActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        Button(intent: OpenQuickLogIntent(action: action)) {
            Label {
                Text(action.titleKey)
            } icon: {
                Image(systemName: action.systemImage)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(action.accessibilityHintKey)
    }
}

private extension Color {
    /// Mirrors the app's adaptive brand tokens. In tinted widget mode iOS
    /// applies the user's system tint; full-colour widgets keep MoneyUp green.
    static let moneyUpSoftGreen = Color(
        uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                if traits.userInterfaceStyle == .dark {
                    return UIColor(
                        red: 164.0 / 255.0,
                        green: 231.0 / 255.0,
                        blue: 202.0 / 255.0,
                        alpha: 1
                    )
                }
                return UIColor(
                    red: 31.0 / 255.0,
                    green: 96.0 / 255.0,
                    blue: 71.0 / 255.0,
                    alpha: 1
                )
            }
            if traits.userInterfaceStyle == .dark {
                return UIColor(
                    red: 130.0 / 255.0,
                    green: 206.0 / 255.0,
                    blue: 174.0 / 255.0,
                    alpha: 1
                )
            }
            return UIColor(
                red: 52.0 / 255.0,
                green: 120.0 / 255.0,
                blue: 95.0 / 255.0,
                alpha: 1
            )
        }
    )

    /// Filled glyphs use contrast-safe forest-green endpoints in each
    /// appearance so the white action symbol remains readable against every
    /// widget canvas. Bright mint remains an accent and tint.
    static let moneyUpAction = Color(
        uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                if traits.userInterfaceStyle == .dark {
                    return UIColor(
                        red: 55.0 / 255.0,
                        green: 123.0 / 255.0,
                        blue: 97.0 / 255.0,
                        alpha: 1
                    )
                }
                return UIColor(
                    red: 36.0 / 255.0,
                    green: 95.0 / 255.0,
                    blue: 73.0 / 255.0,
                    alpha: 1
                )
            }
            if traits.userInterfaceStyle == .dark {
                return UIColor(
                    red: 52.0 / 255.0,
                    green: 127.0 / 255.0,
                    blue: 96.0 / 255.0,
                    alpha: 1
                )
            }
            return UIColor(
                red: 52.0 / 255.0,
                green: 120.0 / 255.0,
                blue: 95.0 / 255.0,
                alpha: 1
            )
        }
    )

    static let moneyUpActionDeep = Color(
        uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                if traits.userInterfaceStyle == .dark {
                    return UIColor(
                        red: 50.0 / 255.0,
                        green: 118.0 / 255.0,
                        blue: 91.0 / 255.0,
                        alpha: 1
                    )
                }
                return UIColor(
                    red: 23.0 / 255.0,
                    green: 74.0 / 255.0,
                    blue: 55.0 / 255.0,
                    alpha: 1
                )
            }
            return UIColor(
                red: 37.0 / 255.0,
                green: 92.0 / 255.0,
                blue: 72.0 / 255.0,
                alpha: 1
            )
        }
    )

    static let moneyUpWidgetBackground = Color(
        uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                if traits.userInterfaceStyle == .dark {
                    return UIColor(
                        red: 18.0 / 255.0,
                        green: 26.0 / 255.0,
                        blue: 22.0 / 255.0,
                        alpha: 1
                    )
                }
                return UIColor(
                    red: 252.0 / 255.0,
                    green: 253.0 / 255.0,
                    blue: 251.0 / 255.0,
                    alpha: 1
                )
            }
            if traits.userInterfaceStyle == .dark {
                return UIColor(
                    red: 24.0 / 255.0,
                    green: 33.0 / 255.0,
                    blue: 29.0 / 255.0,
                    alpha: 1
                )
            }
            return UIColor(
                red: 247.0 / 255.0,
                green: 249.0 / 255.0,
                blue: 246.0 / 255.0,
                alpha: 1
            )
        }
    )
}

private struct MoneyUpQuickActionsWidget: Widget {
    // Retain the prior identifier; TestFlight upgrade behavior from the old
    // static configuration still requires an on-device migration check.
    let kind = "MoneyUpQuickLog"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: MoneyUpWidgetConfigurationIntent.self,
            provider: MoneyUpWidgetProvider()
        ) { entry in
            MoneyUpWidgetView(entry: entry)
        }
        .configurationDisplayName("widget.display_name")
        .description("widget.description")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
