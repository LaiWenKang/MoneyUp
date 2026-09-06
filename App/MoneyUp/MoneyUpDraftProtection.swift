import SwiftUI

private struct MoneyUpDraftProtection: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDiscard = false
    let hasChanges: Bool
    let isSaving: Bool
    let cancellationTitle: LocalizedStringKey

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(hasChanges || isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancellationTitle) {
                        if hasChanges { isConfirmingDiscard = true }
                        else { dismiss() }
                    }
                    .disabled(isSaving)
                }
            }
            .confirmationDialog("draft.discard_title", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("draft.discard_changes", role: .destructive) { dismiss() }
                Button("draft.keep_editing", role: .cancel) {}
            }
    }
}

extension View {
    func moneyUpProtectDraft(
        hasChanges: Bool, isSaving: Bool, cancellationTitle: LocalizedStringKey = "action.cancel"
    ) -> some View {
        modifier(MoneyUpDraftProtection(hasChanges: hasChanges, isSaving: isSaving, cancellationTitle: cancellationTitle))
    }
}
