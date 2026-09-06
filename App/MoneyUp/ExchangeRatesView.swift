import MoneyUpCore
import SwiftUI

struct ExchangeRatesView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var pendingDeletionID: UUID?
    @State private var isConfirmingDeletion = false

    var body: some View {
        Form {
            Section {
                Button { isAdding = true } label: {
                    Label("fx.add_rate", systemImage: "plus.circle.fill")
                }
            }

            Section {
                if model.exchangeRates.isEmpty {
                    ContentUnavailableView(
                        "fx.no_rates",
                        systemImage: "equal.circle",
                        description: Text("fx.unconverted_detail")
                    )
                } else {
                    ForEach(model.exchangeRates) { rate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(rate.baseCurrency.value) → \(rate.quoteCurrency.value)")
                                .fontWeight(.semibold)
                            Text(
                                "1 \(rate.baseCurrency.value) = \(NSDecimalNumber(decimal: rate.rate).stringValue) \(rate.quoteCurrency.value)"
                            )
                            .font(.subheadline.monospacedDigit())
                            Text(
                                String(
                                    format: AppLocalization.string("fx.effective_day_format"),
                                    rate.effectiveContext.dayKey,
                                    rate.effectiveContext.timeZoneIdentifier
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDeletionID = rate.id
                                isConfirmingDeletion = true
                            } label: {
                                Label("action.delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("fx.saved_rates")
            } footer: {
                MoneyUpExplainer("fx.estimated_detail")
            }

        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("fx.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { MoneyUpKeyboardDoneToolbar() }
        .sheet(isPresented: $isAdding) { ExchangeRateEditorSheet() }
        .confirmationDialog(
            "fx.delete_title",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("action.delete", role: .destructive) {
                guard let id = pendingDeletionID else { return }
                Task { await delete(id) }
            }
            Button("action.cancel", role: .cancel) { pendingDeletionID = nil }
        } message: {
            Text("fx.delete_detail")
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private func delete(_ id: UUID) async {
        do {
            try await model.deleteExchangeRate(id: id)
            pendingDeletionID = nil
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
