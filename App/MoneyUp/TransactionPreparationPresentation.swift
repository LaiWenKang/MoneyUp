import MoneyUpCore
import SwiftUI

private struct TransactionPreparationHandlerKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (JournalEntry, TransactionPreparationAction) -> Void)? = nil
}

extension EnvironmentValues {
    var prepareTransaction: (@MainActor @Sendable (JournalEntry, TransactionPreparationAction) -> Void)? {
        get { self[TransactionPreparationHandlerKey.self] }
        set { self[TransactionPreparationHandlerKey.self] = newValue }
    }
}

struct TransactionPreparationActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.prepareTransaction) private var prepare
    let entry: JournalEntry

    var body: some View {
        if let prepare, !model.isProtectedJournalEntry(entry),
           TransactionPreparationPolicy.draft(
               from: entry, action: .repeatEntry, accounts: model.accounts,
               now: model.currentDateForUserAction()
           ) != nil {
            Button { prepare(entry, .repeatEntry) } label: {
                Label("transaction.repeat", systemImage: "repeat")
            }
            if let values = EditableEntryValues(entry: entry, accounts: model.accounts),
               values.kind == .expense {
                Button { prepare(entry, .refund) } label: {
                    Label("transaction.refund", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }
}

struct TransactionPreparationPresenter: ViewModifier {
    let openLog: @MainActor () -> Void

    func body(content: Content) -> some View {
        TransactionPreparationContent(content: content, openLog: openLog)
    }
}

private struct TransactionPreparationContent<Content: View>: View {
    private struct Request {
        let entry: JournalEntry
        let action: TransactionPreparationAction
        let expectedDraft: QuickLogDraft?
    }

    @Environment(AppModel.self) private var model
    @State private var pending: Request?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    let content: Content
    let openLog: @MainActor () -> Void

    var body: some View {
        content
            .disabled(isPreparing)
            .environment(\.prepareTransaction, { entry, action in
                guard !isPreparing else { return }
                let request = Request(entry: entry, action: action, expectedDraft: model.quickLogDraft)
                if model.quickLogDraft?.hasUserEdits == true {
                    pending = request
                } else {
                    prepare(request)
                }
            })
            .confirmationDialog(
                "quick_log.unfinished_title",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                Button("quick_log.resume_draft") { pending = nil; openLog() }
                Button("transaction.replace_draft", role: .destructive) {
                    guard let request = pending else { return }
                    pending = nil
                    prepare(request)
                }
                Button("action.cancel", role: .cancel) { pending = nil }
            } message: {
                Text("transaction.prepare_draft_detail")
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private func prepare(_ request: Request) {
        isPreparing = true
        Task { @MainActor in
            defer { isPreparing = false }
            do {
                try await model.prepareTransaction(
                    from: request.entry, action: request.action, replacing: request.expectedDraft
                )
                guard model.state == .ready else { return }
                MoneyUpKeyboard.dismiss()
                openLog()
            } catch {
                errorMessage = safeUserMessage(for: error, context: .write)
            }
        }
    }
}
