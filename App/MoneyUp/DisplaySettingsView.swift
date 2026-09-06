import MoneyUpCore
import SwiftUI

struct DisplaySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("display.daily_guidance", isOn: preference(\.showsDailyGuidance))
                Picker("display.guidance_cadence", selection: Binding(
                    get: { model.displayPreferences.preferredGuidanceCadence },
                    set: { cadence in model.changeDisplayPreferences { $0.preferredGuidanceCadence = cadence } }
                )) {
                    Text("plan.pacing.today").tag(BudgetPacingCadence.daily)
                    Text("plan.pacing.this_week").tag(BudgetPacingCadence.weekly)
                    Text("plan.pacing.rest_of_month").tag(BudgetPacingCadence.monthly)
                }
            } footer: {
                MoneyUpExplainer("display.guidance_detail")
            }
            Section {
                ForEach(model.budgetNodeOutline) { item in
                    Toggle(isOn: Binding(
                        get: {
                            !model.displayPreferences.hiddenGuidanceCategoryIDs.contains(item.id)
                        },
                        set: { visible in
                            model.changeDisplayPreferences {
                                $0.setGuidanceVisible(visible, for: item.id)
                            }
                        }
                    )) {
                        Text(item.node.name)
                            .fontWeight(item.depth == 0 ? .semibold : .regular)
                    }
                    .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
                    .accessibilityLabel(model.categoryPathName(for: item.id))
                }
            } header: {
                Text("display.category_guidance")
            } footer: {
                MoneyUpExplainer(model.displayPreferences.showsDailyGuidance
                    ? "display.category_guidance_detail" : "display.guidance_hidden_detail")
            }
            Section("display.appearance") {
                Toggle("display.illustrations", isOn: preference(\.showsIllustrations))
                Toggle("display.today_trend", isOn: preference(\.showsTodayTrend))
                Toggle("display.reduce_motion", isOn: preference(\.reducesMotion))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("display.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func preference(_ path: WritableKeyPath<MoneyUpDisplayPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.displayPreferences[keyPath: path] },
            set: { enabled in model.changeDisplayPreferences { $0[keyPath: path] = enabled } }
        )
    }
}
