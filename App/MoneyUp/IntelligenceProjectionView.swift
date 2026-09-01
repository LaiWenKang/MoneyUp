import MoneyUpCore
import MoneyUpIntelligence
import SwiftUI

struct IntelligenceProjectionCard: View {
    @Environment(AppModel.self) private var model
    @State private var result: DerivedValue<[MonthEndProjection]>?

    var body: some View {
        if model.profile?.intelligenceEnabled == true {
            MoneyUpCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(
                            "intelligence.projection.title",
                            systemImage: "chart.line.uptrend.xyaxis"
                        )
                        .font(.headline)
                        Spacer(minLength: 8)
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("action.refresh")
                    }
                    Text("intelligence.projection.detail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    projectionContent
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var projectionContent: some View {
        switch result {
        case .none:
            ProgressView()
                .frame(maxWidth: .infinity)
        case let .some(.available(projections)):
            if projections.isEmpty {
                Text("intelligence.projection.no_activity")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projections, id: \.projectedTotal.currency) { projection in
                    projectionRows(projection)
                }
            }
        case let .some(.unavailable(issue)):
            DerivedValueUnavailableView(issue: issue)
        }
    }

    private func projectionRows(
        _ projection: MonthEndProjection
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(projection.projectedTotal.currency.value)
                .font(.subheadline.bold())
            LabeledContent(
                "intelligence.projection.actuals",
                value: formattedMoney(projection.committedActuals)
            )
            LabeledContent(
                "intelligence.projection.schedules",
                value: formattedMoney(projection.remainingSchedules)
            )
            LabeledContent(
                "intelligence.projection.flexible_burn",
                value: formattedMoney(projection.flexibleBurnRateProjection)
            )
            Divider()
            LabeledContent {
                Text(formattedMoney(projection.projectedTotal))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            } label: {
                Text("intelligence.projection.projected")
                    .fontWeight(.semibold)
            }
            Text(projectionAssumption(projection))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }

    private func projectionAssumption(
        _ projection: MonthEndProjection
    ) -> String {
        String(
            format: AppLocalization.string(
                "intelligence.projection.assumption_format"
            ),
            projection.elapsedDayCount,
            projection.remainingDayCount,
            projection.ruleID
        )
    }

    @MainActor
    private func load() async {
        result = nil
        result = await model.monthEndProjectionResult()
    }
}
