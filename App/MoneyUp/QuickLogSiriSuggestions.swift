import AppIntents

/// After a save, Siri learns only which Log was used, so Siri Suggestions can
/// offer that Log at a similar time. The donation is the closed action alone:
/// no amount, payee, account, category, note, or record identifier.
enum QuickLogSiriSuggestions {
    static func action(for kind: QuickLogKind) -> MoneyUpQuickAction {
        switch kind {
        case .expense: .expense
        case .income: .income
        case .transfer: .transfer
        case .refund: .refund
        }
    }

    @MainActor
    static func donate(_ kind: QuickLogKind) {
        let intent = OpenQuickLogIntent(action: action(for: kind))
        // On the next turn, so the save never waits on Siri.
        Task { _ = intent.donate() }
    }
}
