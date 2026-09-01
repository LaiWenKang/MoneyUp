import Foundation
import SwiftUI

/// A stable snapshot prevents a native alert from being recreated while the
/// same failure remains published. The alert itself owns VoiceOver focus and
/// announcement, so MoneyUp never posts a second accessibility notification.
struct MoneyUpOperationErrorPresentation: Equatable, Identifiable {
    let id: Int
    let message: String
}

struct MoneyUpOperationErrorPresentationState: Equatable {
    private(set) var active: MoneyUpOperationErrorPresentation?
    private(set) var presentationCount = 0
    private(set) var pendingMessage: String?
    private(set) var isCompletingDismissal = false

    /// While an alert is visible, keep only the newest distinct failure. If a
    /// failure arrives after dismissal but before the queued promotion runs,
    /// it replaces that queued value rather than activating beside stale work.
    mutating func receive(_ candidate: String?) {
        guard let candidate,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if isCompletingDismissal {
            pendingMessage = candidate
            return
        }
        if let active {
            pendingMessage = active.message == candidate ? nil : candidate
            return
        }
        guard pendingMessage == nil else {
            pendingMessage = candidate
            return
        }
        activate(candidate)
    }

    @discardableResult
    mutating func beginDismissal(bindingSnapshot: String?) -> Bool {
        receive(bindingSnapshot)
        guard active != nil else { return false }
        active = nil
        isCompletingDismissal = true
        return true
    }

    mutating func completeDismissal(bindingSnapshot: String?) {
        guard isCompletingDismissal else { return }
        receive(bindingSnapshot)
        isCompletingDismissal = false
        promotePending()
    }

    private mutating func promotePending() {
        guard active == nil, let pendingMessage else { return }
        self.pendingMessage = nil
        activate(pendingMessage)
    }

    private mutating func activate(_ message: String) {
        presentationCount += 1
        active = MoneyUpOperationErrorPresentation(
            id: presentationCount,
            message: message
        )
    }
}

private struct MoneyUpOperationErrorAlertModifier: ViewModifier {
    @Binding var message: String?
    @State private var presentation = MoneyUpOperationErrorPresentationState()
    @State private var dismissalGeneration = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: message, initial: true) { _, newValue in
                presentation.receive(newValue)
            }
            .task(id: dismissalGeneration) {
                guard dismissalGeneration > 0 else { return }
                await Task.yield()
                // This second binding snapshot is intentionally taken only
                // after SwiftUI has processed the dismissal state update. It
                // recovers an identical A -> nil -> A failure even when
                // onChange coalesces those writes into no observable change.
                presentation.completeDismissal(bindingSnapshot: message)
            }
            .alert(
                "error.operation_failed_title",
                isPresented: Binding(
                    get: { presentation.active != nil },
                    set: { isPresented in
                        if !isPresented { dismiss() }
                    }
                )
            ) {
                Button("action.okay", role: .cancel) {}
            } message: {
                Text(presentation.active?.message ?? "")
            }
    }

    private func dismiss() {
        // Capture before and after the explicit SwiftUI update boundary. The
        // first snapshot preserves a value whose onChange callback is late;
        // the post-yield snapshot recovers a same-message republish that
        // SwiftUI can otherwise coalesce with the dismissed value.
        guard presentation.beginDismissal(bindingSnapshot: message) else { return }
        message = nil
        dismissalGeneration += 1
    }
}

private struct MoneyUpFieldValidationModifier: ViewModifier {
    let message: String?

    func body(content: Content) -> some View {
        if let message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.accessibilityHint(message)
        } else {
            content
        }
    }
}

extension View {
    /// Presents one native, modal accessibility summary for a safe localized
    /// operation failure. Dismissal clears only the error, never form input.
    func moneyUpOperationErrorAlert(message: Binding<String?>) -> some View {
        modifier(MoneyUpOperationErrorAlertModifier(message: message))
    }

    /// Associates validation guidance with its input without turning a
    /// correctable field issue into a modal system-failure alert.
    func moneyUpFieldValidation(_ message: String?) -> some View {
        modifier(MoneyUpFieldValidationModifier(message: message))
    }
}

struct MoneyUpFieldError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text(
                    String(
                        format: AppLocalization.string("error.field_format"),
                        message
                    )
                )
            )
    }
}
