import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import SwiftUI

struct IntelligenceSummaryLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.profile?.intelligenceEnabled == true {
            if model.intelligenceIsUnavailable || !model.intelligenceFindings.isEmpty {
                attentionCard
            } else {
                quietRow
            }
        }
    }

    /// Nothing to do reads as a quiet, completed state: the same card shape as
    /// every other Today surface, a check glyph, and two short words.
    private var quietRow: some View {
        MoneyUpCard(style: .flat) {
            NavigationLink { IntelligenceView() } label: {
                HStack(spacing: 12) {
                    MoneyUpSymbolBadge(
                        systemImage: model.isIntelligenceRefreshing ? "sparkles" : "checkmark.seal.fill",
                        color: model.isIntelligenceRefreshing ? .accentColor : Color.moneyUpPositive
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("intelligence.title")
                            .font(.subheadline.weight(.semibold))
                        Text(summaryKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if model.isIntelligenceRefreshing {
                        ProgressView()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-insights-link")
        }
    }

    private var attentionCard: some View {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var historySelection: IntelligenceHistorySelection?
    @State private var scheduleSelection: IntelligenceScheduleSelection?
    @State private var isShowingReviewed = false
    @State private var busyFindingID: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MoneyUpLayout.standardSpacing) {
                statusCard
                if model.isIntelligenceRefreshing {
                    MoneyUpCard {
                        MoneyUpLoadingPlaceholder(title: "intelligence.summary.refreshing")
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
                if !model.isIntelligenceRefreshing, !model.intelligenceIsUnavailable {
                    reviewedSection
                }
            }
            .padding()
            .frame(maxWidth: MoneyUpLayout.readableContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background { MoneyUpBackdrop() }
        .navigationTitle("intelligence.title")
            .moneyUpNavigationSurface()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        model.refreshIntelligence()
                    } label: {
                        Label("action.refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isIntelligenceRefreshing)
                    Button {
                        Task { await markAllReviewed() }
                    } label: {
                        Label("intelligence.mark_all_reviewed", systemImage: "checkmark.circle")
                    }
                    .disabled(model.intelligenceFindings.isEmpty || busyFindingID != nil)
                } label: {
                    Label("action.more", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("intelligence-more")
            }
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
        .sheet(item: $historySelection) { selection in
            IntelligenceHistoryReviewView(selection: selection)
        }
        .sheet(item: $scheduleSelection) { selection in
            IntelligenceScheduleReviewView(selection: selection)
        }
        .onChange(of: model.logicalBookRevision) { _, _ in
            historySelection = nil
            scheduleSelection = nil
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
                    .foregroundStyle(Color.moneyUpWarning)
                }
                if model.intelligenceIsUnavailable {
                    Label(
                        "intelligence.unavailable",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.moneyUpWarning)
                }
            }
        }
    }

    private var emptyCard: some View {
        MoneyUpCard {
            MoneyUpStatePlaceholder(
                systemImage: "checkmark.seal.fill",
                tint: Color.moneyUpPositive,
                title: "intelligence.clear_title",
                detail: "intelligence.clear_detail"
            )
        }
    }

    @ViewBuilder
    private var reviewedSection: some View {
        let reviewed = model.reviewedIntelligenceFindings
        if !reviewed.isEmpty {
            MoneyUpCard(style: .flat) {
                DisclosureGroup(isExpanded: $isShowingReviewed) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("intelligence.reviewed_detail")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(reviewed) { finding in
                            reviewedRow(finding)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label {
                        HStack(spacing: 8) {
                            Text("intelligence.reviewed_section")
                            Text(reviewed.count.formatted())
                                .font(.caption.bold().monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("intelligence-reviewed")
            }
        }
    }

    private func reviewedRow(_ finding: IntelligenceFinding) -> some View {
        HStack(spacing: 10) {
            Image(systemName: finding.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(LocalizedStringKey(finding.headlineKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                Task { await restore(finding) }
            } label: {
                Label("intelligence.restore_finding", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busyFindingID != nil)
            .accessibilityLabel(Text("intelligence.restore_finding"))
        }
        .frame(minHeight: 44)
    }

    @MainActor
    private func markReviewed(_ finding: IntelligenceFinding) async {
        guard busyFindingID == nil else { return }
        busyFindingID = finding.id
        defer { busyFindingID = nil }
        do {
            try await model.markIntelligenceFindingReviewed(finding.id)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    @MainActor
    private func restore(_ finding: IntelligenceFinding) async {
        guard busyFindingID == nil else { return }
        busyFindingID = finding.id
        defer { busyFindingID = nil }
        do {
            try await model.restoreIntelligenceFinding(finding.id)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    @MainActor
    private func markAllReviewed() async {
        guard busyFindingID == nil else { return }
        busyFindingID = "all"
        defer { busyFindingID = nil }
        do {
            try await model.markAllIntelligenceFindingsReviewed()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        routeControl(finding)
                        Spacer(minLength: 0)
                        reviewedButton(finding)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        routeControl(finding)
                        reviewedButton(finding)
                    }
                }
            }
        }
        .animation(MoneyUpMotion.animation(for: .stateChange, reduceMotion: reduceMotion), value: busyFindingID)
    }

    private func reviewedButton(_ finding: IntelligenceFinding) -> some View {
        Button {
            Task { await markReviewed(finding) }
        } label: {
            Label("intelligence.mark_reviewed", systemImage: "checkmark")
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
        .disabled(busyFindingID != nil)
        .accessibilityIdentifier("intelligence-mark-reviewed")
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
                    wasTruncated: entryIDs.count > maximum,
                    logicalBookRevision: model.logicalBookRevision
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
        case .possibleDuplicate, .priceIncrease, .categoryAnomaly: Color.moneyUpWarning
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
