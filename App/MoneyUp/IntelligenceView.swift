import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import SwiftUI

struct IntelligenceSummaryLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.profile?.intelligenceEnabled == true {
            MoneyUpCard {
                NavigationLink {
                    IntelligenceView()
                } label: {
                    HStack(spacing: 12) {
                        MoneyUpSymbolBadge(
                            systemImage: "sparkles",
                            color: .accentColor
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text("intelligence.title")
                                .font(.headline)
                            Text(summaryKey)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if model.isIntelligenceRefreshing {
                            ProgressView()
                        } else if !model.intelligenceFindings.isEmpty {
                            Text(model.intelligenceFindings.count.formatted())
                                .font(.caption.bold().monospacedDigit())
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summaryKey: LocalizedStringKey {
        if model.intelligenceIsUnavailable {
            return "intelligence.summary.unavailable"
        }
        if model.isIntelligenceRefreshing {
            return "intelligence.summary.refreshing"
        }
        return model.intelligenceFindings.isEmpty
            ? "intelligence.summary.clear"
            : "intelligence.summary.findings"
    }
}

struct IntelligenceView: View {
    @Environment(AppModel.self) private var model
    @State private var historySelection: IntelligenceHistorySelection?
    @State private var scheduleSelection: IntelligenceScheduleSelection?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MoneyUpLayout.standardSpacing) {
                statusCard
                if model.isIntelligenceRefreshing {
                    MoneyUpCard {
                        ProgressView("intelligence.summary.refreshing")
                            .frame(maxWidth: .infinity)
                    }
                } else if model.intelligenceIsUnavailable {
                    EmptyView()
                } else if model.intelligenceFindings.isEmpty {
                    emptyCard
                } else {
                    ForEach(model.intelligenceFindings) { finding in
                        findingCard(finding)
                    }
                }
            }
            .padding()
            .frame(maxWidth: MoneyUpLayout.readableContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background { MoneyUpBackdrop() }
        .navigationTitle("intelligence.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshIntelligence()
                } label: {
                    Label("action.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isIntelligenceRefreshing)
            }
        }
        .sheet(item: $historySelection) { selection in
            IntelligenceHistoryReviewView(selection: selection)
        }
        .sheet(item: $scheduleSelection) { selection in
            IntelligenceScheduleReviewView(selection: selection)
        }
    }

    private var statusCard: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("intelligence.private_title", systemImage: "lock.shield.fill")
                    .font(.headline)
                Text("intelligence.private_detail")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if model.intelligenceResultsAreLimited {
                    Label(
                        "intelligence.limited",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
                if model.intelligenceIsUnavailable {
                    Label(
                        "intelligence.unavailable",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var emptyCard: some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("intelligence.clear_title", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("intelligence.clear_detail")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func findingCard(_ finding: IntelligenceFinding) -> some View {
        MoneyUpCard {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(LocalizedStringKey(finding.headlineKey))
                        .font(.headline)
                } icon: {
                    Image(systemName: finding.kind.systemImage)
                        .foregroundStyle(finding.kind.tint)
                }
                Text(LocalizedStringKey(finding.explanationKey))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Array(finding.figures.enumerated()), id: \.offset) {
                    _, figure in
                    LabeledContent {
                        Text(formattedFigure(figure.value))
                            .monospacedDigit()
                    } label: {
                        Text(LocalizedStringKey(figure.labelKey))
                    }
                    .font(.footnote)
                }
                HStack(spacing: 8) {
                    Text(confidenceKey(finding.confidence))
                    Text("·")
                    Text(
                        String(
                            format: AppLocalization.string(
                                "intelligence.samples_format"
                            ),
                            finding.sampleSize
                        )
                    )
                    Text("·")
                    Text(finding.ruleID)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                routeControl(finding)
            }
        }
    }

    @ViewBuilder
    private func routeControl(_ finding: IntelligenceFinding) -> some View {
        switch finding.route {
        case let .history(entryIDs, day):
            Button {
                let maximum = AppModel.maximumIntelligenceHistoryReviewCount
                historySelection = IntelligenceHistorySelection(
                    findingID: finding.id,
                    entryIDs: Array(entryIDs.suffix(maximum)),
                    day: day,
                    wasTruncated: entryIDs.count > maximum
                )
            } label: {
                Label("intelligence.review_history", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
        case let .scheduleOffer(offer):
            Button {
                scheduleSelection = IntelligenceScheduleSelection(
                    findingID: finding.id,
                    ruleID: finding.ruleID,
                    offer: offer
                )
            } label: {
                Label("intelligence.review_schedule", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.moneyUpAction)
        case .plan:
            NavigationLink {
                PlanView()
            } label: {
                Label("intelligence.review_plan", systemImage: "chart.pie.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    private func formattedFigure(_ value: IntelligenceFigureValue) -> String {
        switch value {
        case let .money(money):
            formattedMoney(money)
        case let .count(count):
            count.formatted()
        case let .day(day):
            formattedIntelligenceDay(day)
        case let .decimal(decimal):
            NSDecimalNumber(decimal: decimal).stringValue
        }
    }

    private func formattedIntelligenceDay(_ value: Int) -> String {
        guard let date = intelligenceDate(value, calendar: model.reportingCalendar) else {
            return String(value)
        }
        return date.formattedForReporting(
            .dateTime.year().month().day(),
            calendar: model.reportingCalendar
        )
    }

    private func confidenceKey(
        _ confidence: IntelligenceConfidence
    ) -> LocalizedStringKey {
        confidence == .high
            ? "intelligence.confidence.high"
            : "intelligence.confidence.medium"
    }
}

extension IntelligenceFindingKind {
    fileprivate var systemImage: String {
        switch self {
        case .recurrence: "repeat"
        case .lapsedSubscription: "calendar.badge.exclamationmark"
        case .priceIncrease: "arrow.up.right"
        case .possibleDuplicate: "doc.on.doc"
        case .categoryAnomaly: "waveform.path.ecg"
        case .budgetSuggestion: "chart.pie.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .possibleDuplicate, .priceIncrease, .categoryAnomaly: .orange
        case .lapsedSubscription: .secondary
        case .recurrence, .budgetSuggestion: .accentColor
        }
    }
}

func intelligenceDate(_ value: Int, calendar: Calendar) -> Date? {
    let components = DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: value / 10_000,
        month: value / 100 % 100,
        day: value % 100,
        hour: 12
    )
    guard let date = calendar.date(from: components),
          FinancialPeriodBoundary.dayKey(for: date, calendar: calendar) == value else {
        return nil
    }
    return date
}
