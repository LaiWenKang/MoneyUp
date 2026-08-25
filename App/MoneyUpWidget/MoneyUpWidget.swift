import AppIntents
import SwiftUI
import WidgetKit

@main
struct MoneyUpWidgetBundle: WidgetBundle {
    var body: some Widget {
        MoneyUpQuickActionsWidget()
    }
}

enum MoneyUpQuickAction: String, AppEnum, CaseIterable, Identifiable, Sendable {
    case expense
    case income
    case transfer
    case smartEntry
    case scanReceipt

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        "widget.configuration.action_type"

    static let caseDisplayRepresentations: [MoneyUpQuickAction: DisplayRepresentation] = [
        .expense: "widget.action.expense",
        .income: "widget.action.income",
        .transfer: "widget.action.transfer",
        .smartEntry: "widget.action.smart_entry",
        .scanReceipt: "widget.action.scan_receipt"
    ]

    static func mediumActions(
        preferred: MoneyUpQuickAction
    ) -> [MoneyUpQuickAction] {
        let fallback: [MoneyUpQuickAction] = [
            .expense,
            .income,
            .transfer,
            .scanReceipt,
            .smartEntry
        ]
        return [preferred] + Array(fallback.filter { $0 != preferred }.prefix(3))
    }

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .expense:
            "widget.action.expense"
        case .income:
            "widget.action.income"
        case .transfer:
            "widget.action.transfer"
        case .smartEntry:
            "widget.action.smart_entry"
        case .scanReceipt:
            "widget.action.scan_receipt"
        }
    }

    var systemImage: String {
        switch self {
        case .expense:
            "arrow.up.right"
        case .income:
            "arrow.down.left"
        case .transfer:
            "arrow.left.arrow.right"
        case .smartEntry:
            "sparkles"
        case .scanReceipt:
            "doc.text.viewfinder"
        }
    }

    var deepLink: URL {
        switch self {
        case .expense:
            URL(string: "moneyup://quick-log/expense")!
        case .income:
            URL(string: "moneyup://quick-log/income")!
        case .transfer:
            URL(string: "moneyup://quick-log/transfer")!
        case .smartEntry:
            URL(string: "moneyup://quick-log/smart-entry")!
        case .scanReceipt:
            URL(string: "moneyup://quick-log/scan-receipt")!
        }
    }
}

struct MoneyUpWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.configuration.title"
    static let description = IntentDescription("widget.configuration.description")

    @Parameter(
        title: "widget.configuration.default_action",
        default: MoneyUpQuickAction.expense
    )
    var defaultAction: MoneyUpQuickAction
}

private struct MoneyUpWidgetEntry: TimelineEntry {
    let date: Date
    let action: MoneyUpQuickAction
}

private struct MoneyUpWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MoneyUpWidgetEntry {
        MoneyUpWidgetEntry(date: Date(), action: .expense)
    }

    func snapshot(
        for configuration: MoneyUpWidgetConfigurationIntent,
        in context: Context
    ) async -> MoneyUpWidgetEntry {
        MoneyUpWidgetEntry(date: Date(), action: configuration.defaultAction)
    }

    func timeline(
        for configuration: MoneyUpWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<MoneyUpWidgetEntry> {
        let entry = MoneyUpWidgetEntry(date: Date(), action: configuration.defaultAction)
        return Timeline(entries: [entry], policy: .never)
    }
}

private struct MoneyUpWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MoneyUpWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                MediumQuickActionsView(preferredAction: entry.action)
            case .accessoryCircular:
                AccessoryCircularActionView(action: entry.action)
            case .accessoryRectangular:
                AccessoryRectangularActionView(action: entry.action)
            case .accessoryInline:
                AccessoryInlineActionView(action: entry.action)
            default:
                SmallQuickActionView(action: entry.action)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .tint(.moneyUpRoyalBlue)
        .widgetURL(family == .systemMedium ? nil : entry.action.deepLink)
    }
}

private struct SmallQuickActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.tint)
                Text("widget.title")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            Image(systemName: action.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.moneyUpRoyalBlue, in: Circle())
                .accessibilityHidden(true)

            Text(action.titleKey)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("widget.tap_to_open")
    }
}

private struct MediumQuickActionsView: View {
    let preferredAction: MoneyUpQuickAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.tint)
                Text("widget.title")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("widget.quick_actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(
                    MoneyUpQuickAction.mediumActions(preferred: preferredAction)
                ) { action in
                    Link(destination: action.deepLink) {
                        VStack(spacing: 7) {
                            Image(systemName: action.systemImage)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.moneyUpRoyalBlue, in: Circle())
                            Text(action.titleKey)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("widget.tap_to_open")
                }
            }
        }
    }
}

private struct AccessoryCircularActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: action.systemImage)
                .font(.title3.weight(.semibold))
                .widgetAccentable()
        }
        .accessibilityLabel(action.titleKey)
        .accessibilityHint("widget.tap_to_open")
    }
}

private struct AccessoryRectangularActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: action.systemImage)
                .font(.title3.weight(.semibold))
                .widgetAccentable()
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("widget.title")
                    .font(.caption2.weight(.semibold))
                Text(action.titleKey)
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("widget.tap_to_open")
    }
}

private struct AccessoryInlineActionView: View {
    let action: MoneyUpQuickAction

    var body: some View {
        Label {
            Text(action.titleKey)
        } icon: {
            Image(systemName: action.systemImage)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("widget.tap_to_open")
    }
}

private extension Color {
    /// Mirrors the app accent. In tinted widget mode iOS applies the user's
    /// selected system tint, while full-colour widgets retain MoneyUp blue.
    static let moneyUpRoyalBlue = Color(
        red: 38.0 / 255.0,
        green: 71.0 / 255.0,
        blue: 196.0 / 255.0
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
