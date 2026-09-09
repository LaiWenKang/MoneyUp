import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    var smartReviewSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("quick_log.editable_preview", systemImage: "pencil.and.list.clipboard")
                .font(.subheadline.weight(.semibold))
            if smartState.issues.isEmpty {
                Text("quick_log.preview_ready").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(smartState.issues, id: \.rawValue) { issue in
                    Label(smartIssueTitle(issue), systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-log-smart-preview")
    }

    var merchantLearningControl: some View {
        Toggle("quick_log.merchant_learning", isOn: Binding(
            get: { model.profile?.merchantSuggestionsEnabled ?? true },
            set: { enabled in
                cancelCaptureSuggestionLookup()
                captureSuggestionResult = nil
                Task {
                    do { try await model.updateMerchantSuggestions(enabled) }
                    catch { errorMessage = safeUserMessage(for: error, context: .save) }
                }
            }
        ))
        .accessibilityHint("quick_log.merchant_learning_detail")
    }
}

private func smartIssueTitle(_ issue: SmartEntryIssue) -> LocalizedStringKey {
        switch issue {
        case .amount: "quick_log.resolve.amount"
        case .currency: "quick_log.resolve.currency"
        case .date: "quick_log.resolve.date"
        case .account: "quick_log.resolve.account"
        case .category: "quick_log.resolve.category"
        case .kind: "quick_log.resolve.kind"
        case .destination: "quick_log.resolve.destination"
        case .receivedAmount: "quick_log.resolve.receivedAmount"
        case .split: "quick_log.resolve.split"
        case .multiple: "quick_log.resolve.multiple"
        case .inputLimit: "quick_log.resolve.inputLimit"
        }
    }
