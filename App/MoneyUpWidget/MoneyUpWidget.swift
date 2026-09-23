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

extension SmartOverviewFocus: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "widget.configuration.focus"
    static let caseDisplayRepresentations: [SmartOverviewFocus: DisplayRepresentation] = [
        .automatic: "widget.focus.automatic",
        .budget: "widget.smart_budget",
        .review: "widget.smart_review",
        .allowance: "widget.smart_allowance",
        .commitments: "widget.smart_commitments_next"
    ]
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

    @Parameter(title: "widget.configuration.focus", default: SmartOverviewFocus.automatic)
    var focus: SmartOverviewFocus
}

private struct MoneyUpWidgetEntry: TimelineEntry {
    let date: Date
    let content: MoneyUpWidgetContent
    var focus: SmartOverviewFocus = .automatic
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
        let surface: MoneyUpWidgetTimelineSurface = switch entry.content {
        case .quickAction: .quickAction
        case .budgetStatus: .budgetStatus
        case .smartOverview: .smartOverview
        }
        let generations = MoneyUpWidgetTimelinePlanner.generations(
            startingAt: entry.date,
            snapshot: MoneyUpWidgetPublishedSnapshot(
                budget: entry.budgetSnapshot,
                insights: entry.insights
            ),
            surface: surface
        )
        let entries = generations.map { generation in
            MoneyUpWidgetEntry(
                date: generation.date,
                content: entry.content,
                focus: entry.focus,
                action: entry.action,
                budgetSnapshot: generation.snapshot.budget,
                insights: generation.snapshot.insights
            )
        }
        let policy: TimelineReloadPolicy = if let expiry = entries.dropFirst().first?.date {
            .after(expiry)
        } else {
            .never
        }
        return Timeline(entries: entries, policy: policy)
    }

    private func makeEntry(
        for configuration: MoneyUpWidgetConfigurationIntent
    ) -> MoneyUpWidgetEntry {
        // The authenticated app is the sole writer. A widget read must never
        // race a publication by writing an older, sanitized generation back.
        let store = BudgetWidgetSnapshotStore(allowsMaintenanceWrites: false)
        let now = Date()
        let snapshot = store.readPublishedSnapshot(now: now)
        return MoneyUpWidgetEntry(
            date: now,
            content: configuration.content,
            focus: configuration.focus,
            action: configuration.defaultAction,
            budgetSnapshot: snapshot.budget,
            insights: snapshot.insights
        )
    }
}

private struct MoneyUpWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: MoneyUpWidgetEntry

    private var homeDensity: MoneyUpWidgetHomeDensity {
        dynamicTypeSize.isAccessibilitySize ? .accessibility : .standard
    }

    var body: some View {
        Group {
            if showsTodayPlusLog {
                // Large summaries are "Today + Log": one readable status on
                // top and the same data-free Quick Log shortcuts below.
                VStack(spacing: 12) {
                    passiveContent
                        .frame(maxHeight: .infinity)
                    QuickLogHomeWidgetView(
                        action: entry.action,
                        family: .medium,
                        homeDensity: homeDensity
                    )
                    .frame(height: homeDensity == .accessibility ? 88 : 132)
                }
            } else {
                passiveContent
            }
        }
        .environment(\.locale, AppLanguagePreference.current.locale)
        .environment(\.moneyUpWidgetEntryDate, entry.date)
        .widgetURL(destinationURL)
        .containerBackground(for: .widget) {
            if showsQuickLogCanvas {
                // The small Quick Log widget is itself the action: one
                // full-bleed MoneyUp green surface instead of a framed button.
                QuickLogWidgetPalette.heroGradient
            } else {
                Color.moneyUpWidgetBackground
            }
        }
        .tint(.moneyUpSoftGreen)
    }

    @ViewBuilder
    private var passiveContent: some View {
        switch entry.content {
        case .budgetStatus where entry.budgetSnapshot.usesQuickActionFallback,
             .smartOverview where entry.budgetSnapshot.usesQuickActionFallback:
            quickActionContent

        case .budgetStatus:
            BudgetStatusWidgetView(
                snapshot: entry.budgetSnapshot,
                family: family,
                homeDensity: homeDensity
            )
        case .smartOverview:
            SmartOverviewWidgetView(
                snapshot: entry.budgetSnapshot,
                insights: entry.insights,
                family: family,
                homeDensity: homeDensity,
                focus: entry.focus
            )
        case .quickAction:
            quickActionContent
        }
    }

    private var showsTodayPlusLog: Bool {
        family == .systemLarge && entry.content != .quickAction
            && !entry.budgetSnapshot.usesQuickActionFallback
    }

    private var showsQuickLogCanvas: Bool {
        family == .systemSmall
            && (entry.content == .quickAction || entry.budgetSnapshot.usesQuickActionFallback)
    }

    private var destinationURL: URL? {
        if entry.content == .quickAction || entry.budgetSnapshot.usesQuickActionFallback {
            return entry.action.deepLink
        }
        return entry.content == .smartOverview
            ? MoneyUpOverviewRoute.today.url : MoneyUpOverviewRoute.budget.url
    }

    @ViewBuilder
    private var quickActionContent: some View {
        switch family {
        case .systemSmall:
            QuickLogHomeWidgetView(action: entry.action, family: .small, homeDensity: homeDensity)
        case .systemMedium:
            QuickLogHomeWidgetView(action: entry.action, family: .medium, homeDensity: homeDensity)
        case .systemLarge:
            QuickLogHomeWidgetView(action: entry.action, family: .large, homeDensity: homeDensity)
        case .accessoryCircular:
            AccessoryCircularActionView(action: entry.action)
        case .accessoryRectangular:
            AccessoryRectangularActionView(action: entry.action)
        case .accessoryInline:
            AccessoryInlineActionView(action: entry.action)
        default:
            QuickLogHomeWidgetView(action: entry.action, family: .small, homeDensity: homeDensity)
        }
    }
}

private struct BudgetStatusWidgetView: View {
    @Environment(\.moneyUpWidgetEntryDate) private var entryDate
    let snapshot: BudgetWidgetSnapshot
    let family: WidgetFamily
    let homeDensity: MoneyUpWidgetHomeDensity
    let language: AppLanguagePreference

    init(
        snapshot: BudgetWidgetSnapshot,
        family: WidgetFamily,
        homeDensity: MoneyUpWidgetHomeDensity,
        language: AppLanguagePreference = .current
    ) {
        self.snapshot = snapshot
        // Large is "Today + Log": the medium status sits above Quick Log.
        self.family = family == .systemLarge ? .systemMedium : family
        self.homeDensity = homeDensity
        self.language = language
    }

    var body: some View {
        switch snapshot {
        case .disabled:
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_enable",
                compactDetail: "widget.budget_disabled_short",
                systemImage: "eye.slash.fill"
            )
        case .needsBudget(_):
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_needs_plan",
                compactDetail: "widget.budget_needs_plan_short",
                systemImage: "chart.pie"
            )
        case .zeroBudget(_):
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_zero_plan",
                compactDetail: "widget.budget_zero_plan_short",
                systemImage: "nosign"
            )
        case .negativeBudget(_):
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_negative_plan",
                compactDetail: "widget.budget_negative_plan_short",
                systemImage: "exclamationmark.triangle.fill"
            )
        case .stale:
            statusMessage(
                title: "widget.budget_status",
                detail: "widget.budget_stale",
                compactDetail: "widget.budget_stale_short",
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
        case .systemSmall:
            if homeDensity.usesReducedBudgetStatus {
                accessibilityAvailableStatus(
                    percentUsed: percentUsed,
                    isOver: isOver
                )
            } else {
                smallAvailableStatus(percentUsed: percentUsed, isOver: isOver)
            }
        case .systemMedium:
            if homeDensity.usesReducedBudgetStatus {
                accessibilityAvailableStatus(
                    percentUsed: percentUsed,
                    isOver: isOver
                )
            } else {
                mediumAvailableStatus(percentUsed: percentUsed, isOver: isOver)
            }
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
            smallAvailableStatus(percentUsed: percentUsed, isOver: isOver)
        }
    }

    private func smallAvailableStatus(
        percentUsed: Int,
        isOver: Bool
    ) -> some View {
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
                .contentTransition(.numericText(value: Double(percentUsed)))
            BudgetPaceBar(percentUsed: percentUsed, elapsed: paceElapsed)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("widget.budget_status")
        .accessibilityValue(percentAccessibility(percentUsed, isOver: isOver))
    }

    private func mediumAvailableStatus(
        percentUsed: Int,
        isOver: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    WidgetBrandHeader()
                    Label {
                        Text(
                            isOver
                                ? LocalizedStringKey("widget.budget_over")
                                : LocalizedStringKey("widget.budget_on_plan")
                        )
                    } icon: {
                        Image(
                            systemName: isOver
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                    }
                    .font(.caption.weight(.semibold))
                }
                Spacer(minLength: 8)
                Text(visiblePercentUsed(percentUsed))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText(value: Double(percentUsed)))
            }
            BudgetPaceBar(percentUsed: percentUsed, elapsed: paceElapsed)
            if let paceElapsed {
                Text(paceCaption(percentUsed: percentUsed, elapsed: paceElapsed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("widget.budget_status")
        .accessibilityValue(percentAccessibility(percentUsed, isOver: isOver))
    }

    private func accessibilityAvailableStatus(
        percentUsed: Int,
        isOver: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(
                    isOver
                        ? LocalizedStringKey("widget.budget_over")
                        : LocalizedStringKey("widget.budget_on_plan")
                )
            } icon: {
                Image(
                    systemName: isOver
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
            }
            .font(.caption.weight(.semibold))
            Text(visiblePercentUsed(percentUsed))
                .font(.body.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("widget.budget_status")
        .accessibilityValue(percentAccessibility(percentUsed, isOver: isOver))
    }

    @ViewBuilder
    private func statusMessage(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        compactDetail: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        switch family {
        case .systemSmall:
            if homeDensity.usesReducedBudgetStatus {
                Label(compactDetail, systemImage: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                    .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    WidgetBrandHeader()
                    Spacer(minLength: 0)
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
        case .systemMedium:
            if homeDensity.usesReducedBudgetStatus {
                Label(compactDetail, systemImage: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                    .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        case .accessoryInline:
            Label(compactDetail, systemImage: systemImage)
        case .accessoryCircular:
            Image(systemName: systemImage)
                .font(.headline)
                .widgetAccentable()
                .accessibilityLabel(compactDetail)
        case .accessoryRectangular:
            HStack(spacing: 7) {
                Image(systemName: systemImage).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption2.weight(.semibold))
                    Text(compactDetail).font(.caption).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
        default:
            Label(compactDetail, systemImage: systemImage)
        }
    }

    private func percentAccessibility(_ percent: Int, isOver: Bool) -> String {
        let status = isOver
            ? AppLocalization.string("widget.budget_over", language: language)
            : AppLocalization.string("widget.budget_on_plan", language: language)
        let usage = String(
            format: AppLocalization.string(
                "widget.budget_accessibility",
                language: language
            ),
            percent,
            status
        )
        guard let paceElapsed else { return usage }
        return usage + " " + paceCaption(percentUsed: percent, elapsed: paceElapsed)
    }

    /// Where today falls in the budget month, from this entry's own date.
    private var paceElapsed: Double? {
        guard case let .available(_, validUntil) = snapshot else { return nil }
        return BudgetPeriodPace.elapsedFraction(periodEnd: validUntil, now: entryDate ?? Date())
    }

    private func paceCaption(percentUsed: Int, elapsed: Double) -> String {
        let monthGone = Int((elapsed * 100).rounded())
        let key = BudgetPeriodPace.isAheadOfPace(percentUsed: percentUsed, elapsed: elapsed)
            ? "widget.budget_pace_ahead_format" : "widget.budget_pace_within_format"
        return String(format: AppLocalization.string(key, language: language), monthGone)
    }

    private func visiblePercentUsed(_ percent: Int) -> String {
        String(
            format: AppLocalization.string(
                "widget.budget_used_format",
                language: language
            ),
            percent
        )
    }
}

/// Wraps each tile of the shared, data-free Quick Log card in the closed
/// action's allowlisted route. This is the only place a Home tile links out.
private struct QuickLogHomeWidgetView: View {
    let action: MoneyUpQuickAction
    let family: QuickLogWidgetLayoutFamily
    let homeDensity: MoneyUpWidgetHomeDensity

    var body: some View {
        QuickLogWidgetCard(primary: action, family: family, density: homeDensity) { action, role in
            Link(destination: action.deepLink) {
                QuickLogWidgetTile(action: action, role: role)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AccessoryCircularActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        Link(destination: action.deepLink) {
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
        Link(destination: action.deepLink) {
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
                .accessibilityHidden(true)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.titleKey)
        .accessibilityHint(action.accessibilityHintKey)
    }
}

struct WidgetBrandHeader: View {
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

private struct AccessoryInlineActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        Link(destination: action.deepLink) {
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

extension Color {
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
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

#if DEBUG
private extension MoneyUpWidgetEntry {
    static func preview(
        content: MoneyUpWidgetContent,
        action: MoneyUpQuickAction = .expense
    ) -> Self {
        Self(
            date: .now,
            content: content,
            action: action,
            budgetSnapshot: .available(
                percentUsed: 42,
                validUntil: .distantFuture
            ),
            insights: MoneyUpWidgetInsights(
                reviewCount: 3,
                allowancePercentRemaining: 68,
                activeCommitmentCount: 2,
                daysUntilNextCommitment: 1,
                validUntil: .distantFuture
            )
        )
    }
}

private struct MoneyUpWidgetAccessibilityPreviewSurface: View {
    let family: WidgetFamily
    let language: AppLanguagePreference

    private var previewWidth: CGFloat {
        family == .systemSmall ? 158 : 338
    }

    var body: some View {
        BudgetStatusWidgetView(
            snapshot: .available(
                percentUsed: 112,
                validUntil: .distantFuture
            ),
            family: family,
            homeDensity: .accessibility,
            language: language
        )
        .environment(\.locale, language.locale)
        .environment(\.dynamicTypeSize, .accessibility5)
        .containerBackground(Color.moneyUpWidgetBackground, for: .widget)
        .tint(.moneyUpSoftGreen)
        .frame(width: previewWidth, height: 158)
    }
}

#Preview("Quick action · Small", as: .systemSmall) {
    MoneyUpQuickActionsWidget()
} timeline: {
    MoneyUpWidgetEntry.preview(content: .quickAction)
}

#Preview("Quick action · Medium", as: .systemMedium) {
    MoneyUpQuickActionsWidget()
} timeline: {
    MoneyUpWidgetEntry.preview(content: .quickAction)
}

#Preview("Quick action · Large", as: .systemLarge) {
    MoneyUpQuickActionsWidget()
} timeline: {
    MoneyUpWidgetEntry.preview(content: .quickAction)
    MoneyUpWidgetEntry.preview(content: .quickAction, action: .smartEntry)
}

#Preview("Smart overview · Small", as: .systemSmall) {
    MoneyUpQuickActionsWidget()
} timeline: {
    MoneyUpWidgetEntry.preview(content: .smartOverview)
}

#Preview("Smart overview · Medium", as: .systemMedium) {
    MoneyUpQuickActionsWidget()
} timeline: {
    MoneyUpWidgetEntry.preview(content: .smartOverview)
}

#Preview("Budget status · Small · English · AX5") {
    MoneyUpWidgetAccessibilityPreviewSurface(
        family: .systemSmall,
        language: .english
    )
}

#Preview("Budget status · Small · 简体中文 · AX5") {
    MoneyUpWidgetAccessibilityPreviewSurface(
        family: .systemSmall,
        language: .simplifiedChinese
    )
}

#Preview("Budget status · Medium · English · AX5") {
    MoneyUpWidgetAccessibilityPreviewSurface(
        family: .systemMedium,
        language: .english
    )
}

#Preview("Budget status · Medium · 简体中文 · AX5") {
    MoneyUpWidgetAccessibilityPreviewSurface(
        family: .systemMedium,
        language: .simplifiedChinese
    )
}
#endif
