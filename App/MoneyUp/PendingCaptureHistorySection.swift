import MoneyUpCore
import SwiftUI

struct PendingCaptureHistorySection: View {
    @Environment(AppModel.self) private var model
    @State private var isReviewing = false
    @State private var isConfirmingDiscard = false
    @State private var errorMessage: String?

    /// Retained for the Log banner's policy tests. History itself no longer
    /// hosts this section: a waiting capture is Log's business.
    nonisolated static func isVisible(pendingLockedCaptureCount: Int, draft: QuickLogDraft?) -> Bool {
        pendingLockedCaptureCount > 0
    }

    var body: some View {
        if Self.isVisible(
            pendingLockedCaptureCount: model.pendingLockedCaptureCount,
            draft: model.quickLogDraft
        ) {
            Section {
                HStack(spacing: 12) {
                    MoneyUpSymbolBadge(systemImage: "tray.and.arrow.down.fill", color: Color.moneyUpWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("capture.review_title").font(.subheadline.weight(.semibold))
                        Text("capture.review_detail").font(.caption).foregroundStyle(.moneyUpSecondary)
                    }
                }
                Button {
                    Task { await review() }
                } label: {
                    Label("backup.review_pending_captures", systemImage: "arrow.right.circle.fill")
                }
                .disabled(isReviewing || model.isWorking || model.isJournalMutationInProgress)
                .accessibilityIdentifier("history-open-pending-capture")
                if model.pendingLockedCaptureCount > 0 {
                    Button(role: .destructive) {
                        isConfirmingDiscard = true
                    } label: {
                        Label("capture.discard_pending", systemImage: "trash")
                    }
                    .disabled(isReviewing || model.isWorking || model.isJournalMutationInProgress)
                    .accessibilityIdentifier("history-discard-pending-captures")
                }
            }
            .confirmationDialog(
                "capture.discard_pending",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("capture.discard_pending", role: .destructive) {
                    Task { await discard() }
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("capture.discard_pending_detail")
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func review() async {
        guard !isReviewing else { return }
        isReviewing = true
        defer { isReviewing = false }
        do { try await model.reviewPendingLockedCapturesForBackup() }
        catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    private func discard() async {
        guard !isReviewing else { return }
        isReviewing = true
        defer { isReviewing = false }
        do { try await model.discardPendingLockedCaptures() }
        catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}
