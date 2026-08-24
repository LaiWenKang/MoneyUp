import SwiftUI
import WidgetKit

@main
struct MoneyUpWidgetBundle: WidgetBundle {
    var body: some Widget {
        MoneyUpQuickLogWidget()
    }
}

private struct MoneyUpWidgetEntry: TimelineEntry {
    let date: Date
}

private struct MoneyUpWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MoneyUpWidgetEntry {
        MoneyUpWidgetEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (MoneyUpWidgetEntry) -> Void
    ) {
        completion(MoneyUpWidgetEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<MoneyUpWidgetEntry>) -> Void
    ) {
        completion(Timeline(entries: [MoneyUpWidgetEntry(date: Date())], policy: .never))
    }
}

private struct MoneyUpWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.tint)
                Text("widget.title")
                    .font(.headline)
                Spacer()
            }

            if family == .systemSmall {
                Text("widget.private")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Label("widget.quick_expense", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            } else {
                Text("widget.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Link(destination: URL(string: "moneyup://quick-log/expense")!) {
                        Label("widget.expense", systemImage: "arrow.up.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Link(destination: URL(string: "moneyup://quick-log/income")!) {
                        Label("widget.income", systemImage: "arrow.down.left.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .tint(.moneyUpRoyalBlue)
        .widgetURL(
            family == .systemSmall
                ? URL(string: "moneyup://quick-log/expense")
                : nil
        )
    }
}

private extension Color {
    /// Mirrors the full-colour app accent. In tinted widget mode iOS still
    /// applies the user's selected system tint, as expected.
    static let moneyUpRoyalBlue = Color(
        red: 38.0 / 255.0,
        green: 71.0 / 255.0,
        blue: 196.0 / 255.0
    )
}

private struct MoneyUpQuickLogWidget: Widget {
    let kind = "MoneyUpQuickLog"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MoneyUpWidgetProvider()) { _ in
            MoneyUpWidgetView()
        }
        .configurationDisplayName("widget.display_name")
        .description("widget.description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
