import Foundation
import MoneyUpCore
import PhotosUI
import SwiftUI

enum QuickLogKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case expense
    case income
    case transfer

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .expense: "transaction.expense"
        case .income: "transaction.income"
        case .transfer: "transaction.transfer"
        }
    }
}

/// The permanent, leftmost transaction-entry destination.
///
/// `kind` lives in the tab container so a widget/deep link can both select the
/// Log tab and switch this form to the requested transaction type.
struct LogView: View {
    @Binding var kind: QuickLogKind
    let isActive: Bool
    let launchMode: QuickLogLaunchMode?
    let requestSequence: Int
    let onRequestHandled: @MainActor (QuickLogLaunchMode) -> Void

    var body: some View {
        QuickLogEntryView(
            kind: $kind,
            dismissAfterSave: false,
            isActive: isActive,
            launchMode: launchMode,
            requestSequence: requestSequence,
            onRequestHandled: onRequestHandled
        )
    }
}

/// Kept as a compatibility wrapper for any feature that still needs to present
/// transaction entry modally. The Log tab and sheet share exactly one form and
/// validation path.
struct QuickLogSheet: View {
    @State private var kind: QuickLogKind

    init(initialKind: QuickLogKind = .expense) {
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        QuickLogEntryView(
            kind: $kind,
            dismissAfterSave: true,
            isActive: true,
            launchMode: nil,
            requestSequence: 0,
            onRequestHandled: { _ in }
        )
    }
}

private struct QuickLogEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FocusState private var isAmountFocused: Bool
    @FocusState private var isSmartEntryFocused: Bool

    @Binding var kind: QuickLogKind
    let dismissAfterSave: Bool
    let isActive: Bool
    let launchMode: QuickLogLaunchMode?
    let requestSequence: Int
    let onRequestHandled: @MainActor (QuickLogLaunchMode) -> Void

    @State private var amountText = ""
    @State private var destinationAmountText = ""
    @State private var accountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var occurredAt = Date()
    @State private var dateWasEdited = false
    @State private var payee = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var smartText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var smartMessage: String?
    @State private var lastSavedEntryID: UUID?
    @State private var isUndoing = false
    @State private var successFeedback = 0
    @State private var hasRestoredDraft = false
    @State private var handledRequestSequence = 0
    @State private var isPresentingReceiptPicker = false
    @State private var isHandlingFocusedLaunch = false
    @State private var isConfirmingDraftSwitch = false
    @State private var pendingLaunchMode: QuickLogLaunchMode?
    @State private var receiptScanTask: Task<Void, Never>?
    @State private var receiptScanGeneration = 0

    private var amount: Decimal? {
        guard let value = decimalAmount(from: amountText), value > .zero else { return nil }
        return value
    }

    private var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    private var selectedAccountCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == accountID })?.currency
    }

    private var selectedDestinationCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == destinationAccountID })?.currency
    }

    private var isForeignCurrencyTransfer: Bool {
        kind == .transfer
            && selectedAccountCurrency != nil
            && selectedDestinationCurrency != nil
            && selectedAccountCurrency != selectedDestinationCurrency
    }

    private var destinationAmount: Decimal? {
        guard let value = decimalAmount(from: destinationAmountText), value > .zero else {
            return nil
        }
        return value
    }

    private var canSave: Bool {
        guard !isScanning,
              amount != nil,
              let accountID,
              model.userAccounts.contains(where: { $0.id == accountID }) else {
            return false
        }
        switch kind {
        case .expense, .income:
            return categories.contains { $0.id == categoryID }
        case .transfer:
            return destinationAccountID != nil
                && destinationAccountID != accountID
                && (!isForeignCurrencyTransfer || destinationAmount != nil)
        }
    }

    private var title: LocalizedStringKey {
        dismissAfterSave ? "quick_log.title" : "tab.log"
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker(
                    "transaction.kind",
                    selection: trackedBinding($kind, \.kind)
                ) {
                    ForEach(QuickLogKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Section {
                    TextField(
                        "quick_log.amount",
                        text: trackedBinding($amountText, \.amountText)
                    )
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                        .focused($isAmountFocused)

                    Picker(
                        kind == .transfer ? "transaction.from_account" : "transaction.account",
                        selection: trackedBinding($accountID, \.accountID)
                    ) {
                        ForEach(model.userAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }

                    if kind == .transfer {
                        Picker(
                            "transaction.to_account",
                            selection: trackedBinding(
                                $destinationAccountID,
                                \.destinationAccountID
                            )
                        ) {
                            ForEach(model.userAccounts.filter { $0.id != accountID }) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                        if isForeignCurrencyTransfer {
                            HStack {
                                TextField(
                                    "transaction.received_amount",
                                    text: trackedBinding(
                                        $destinationAmountText,
                                        \.destinationAmountText
                                    )
                                )
                                .keyboardType(.decimalPad)
                                if let currency = selectedDestinationCurrency {
                                    Text(currency.value)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Picker(
                            "transaction.category",
                            selection: trackedBinding($categoryID, \.categoryID)
                        ) {
                            ForEach(categories) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                    }
                }

                if kind != .transfer {
                    smartEntrySection
                }

                Section {
                    DatePicker(
                        "quick_log.date",
                        selection: Binding(
                            get: { occurredAt },
                            set: { newDate in
                                occurredAt = newDate
                                dateWasEdited = true
                                persistUserDraftChange { snapshot in
                                    snapshot.occurredAt = newDate
                                    snapshot.dateWasEdited = true
                                }
                            }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    if kind != .transfer {
                        TextField(
                            "transaction.payee",
                            text: trackedBinding($payee, \.payee)
                        )
                    }
                    TextField(
                        "quick_log.note",
                        text: trackedBinding($note, \.note),
                        axis: .vertical
                    )
                        .lineLimit(2...4)
                }

                if model.userAccounts.isEmpty {
                    Section {
                        Text("transaction.no_accounts")
                            .foregroundStyle(.secondary)
                    }
                } else if kind == .transfer && model.userAccounts.count < 2 {
                    Section {
                        Text("transaction.need_two_accounts")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .disabled(isSaving || isUndoing)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if dismissAfterSave {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("action.cancel") { dismiss() }
                            .disabled(isSaving)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving || isUndoing)
                }
            }
            .onAppear {
                restoreDraftIfAvailable()
                selectDefaults()
                hasRestoredDraft = true
                handleRequestedLaunch()
                if handledRequestSequence == 0 {
                    isAmountFocused = isActive
                }
            }
            .onChange(of: isActive) { _, newValue in
                if newValue {
                    if !isHandlingFocusedLaunch {
                        isAmountFocused = true
                    }
                } else {
                    isAmountFocused = false
                    isSmartEntryFocused = false
                    isHandlingFocusedLaunch = false
                }
            }
            .onChange(of: kind) { _, _ in
                selectDefaults()
                if isActive, !isHandlingFocusedLaunch {
                    isAmountFocused = true
                }
            }
            .onChange(of: requestSequence) { _, _ in
                handleRequestedLaunch()
            }
            .onChange(of: isSaving) { _, newValue in
                if !newValue { handleRequestedLaunch() }
            }
            .onChange(of: isScanning) { _, newValue in
                if !newValue { handleRequestedLaunch() }
            }
            .onChange(of: photoItem) { _, item in
                receiptScanGeneration &+= 1
                let generation = receiptScanGeneration
                receiptScanTask?.cancel()
                guard item != nil else {
                    receiptScanTask = nil
                    return
                }
                receiptScanTask = Task {
                    await scanReceipt(item, generation: generation)
                }
            }
            .onChange(of: accountID) { _, _ in
                if destinationAccountID == accountID {
                    destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
                }
            }
            .onChange(of: draftSnapshot) { _, snapshot in
                guard hasRestoredDraft, !dismissAfterSave else { return }
                model.updateQuickLogDraft(snapshot)
            }
            .onDisappear {
                receiptScanGeneration &+= 1
                receiptScanTask?.cancel()
                receiptScanTask = nil
                isScanning = false
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let lastSavedEntryID {
                HStack(spacing: 12) {
                    Label("quick_log.saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Button("action.undo") {
                        Task { await undo(entryID: lastSavedEntryID) }
                    }
                    .fontWeight(.semibold)
                    .disabled(isUndoing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.large])
        .confirmationDialog(
            "quick_log.unfinished_title",
            isPresented: $isConfirmingDraftSwitch,
            titleVisibility: .visible
        ) {
            Button("quick_log.resume_draft") {
                if let mode = pendingLaunchMode {
                    onRequestHandled(mode)
                }
                pendingLaunchMode = nil
                isHandlingFocusedLaunch = false
                isAmountFocused = true
            }
            Button("quick_log.start_new", role: .destructive) {
                guard let mode = pendingLaunchMode else { return }
                pendingLaunchMode = nil
                discardDraftAndLaunch(mode)
                onRequestHandled(mode)
            }
            Button("action.cancel", role: .cancel) {
                if let mode = pendingLaunchMode {
                    onRequestHandled(mode)
                }
                pendingLaunchMode = nil
            }
        } message: {
            Text("quick_log.unfinished_detail")
        }
        .onChange(of: isConfirmingDraftSwitch) { wasPresented, isPresented in
            guard wasPresented, !isPresented,
                  let mode = pendingLaunchMode else { return }
            // Tapping outside the system dialog is also a cancellation. Ack it
            // so the same external request cannot remain stuck indefinitely.
            pendingLaunchMode = nil
            onRequestHandled(mode)
        }
    }

    private var smartEntrySection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                TextField(
                    "quick_log.smart_placeholder",
                    text: trackedBinding($smartText, \.smartText),
                    axis: .vertical
                )
                    .lineLimit(1...3)
                    .focused($isSmartEntryFocused)
                Button("quick_log.smart_fill") { applyTypedPhrase() }
                    .buttonStyle(.borderless)
                    .disabled(
                        smartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }

            Button {
                isPresentingReceiptPicker = true
            } label: {
                Label("quick_log.scan_receipt", systemImage: "doc.text.viewfinder")
            }
            .disabled(isScanning)
            .photosPicker(
                isPresented: $isPresentingReceiptPicker,
                selection: $photoItem,
                matching: .images
            )

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("quick_log.scanning").foregroundStyle(.secondary)
                }
            }

            if let smartMessage {
                Text(smartMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("quick_log.smart_entry")
        } footer: {
            Text("quick_log.smart_footer")
        }
    }

    private var draftSnapshot: QuickLogDraft {
        QuickLogDraft(
            kind: kind,
            amountText: amountText,
            destinationAmountText: destinationAmountText,
            accountID: accountID,
            destinationAccountID: destinationAccountID,
            categoryID: categoryID,
            occurredAt: occurredAt,
            dateWasEdited: dateWasEdited,
            payee: payee,
            note: note,
            smartText: smartText
        )
    }

    /// Writes direct control edits to the model in the same setter that updates
    /// SwiftUI state. The app-level background callback can therefore flush the
    /// final keystroke even if SwiftUI has not delivered `onChange` yet.
    private func trackedBinding<Value>(
        _ binding: Binding<Value>,
        _ keyPath: WritableKeyPath<QuickLogDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                persistUserDraftChange { snapshot in
                    snapshot[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func persistUserDraftChange(
        _ update: (inout QuickLogDraft) -> Void
    ) {
        guard hasRestoredDraft, !dismissAfterSave else { return }
        var snapshot = draftSnapshot
        update(&snapshot)
        model.updateQuickLogDraft(snapshot)
    }

    private func restoreDraftIfAvailable() {
        guard !dismissAfterSave, let draft = model.quickLogDraft else { return }
        // Restore first. A conflicting widget request is resolved explicitly
        // below instead of silently reinterpreting or discarding this content.
        kind = draft.kind
        amountText = draft.amountText
        destinationAmountText = draft.destinationAmountText
        accountID = draft.accountID
        destinationAccountID = draft.destinationAccountID
        categoryID = draft.categoryID
        occurredAt = draft.hasTransactionContent ? draft.occurredAt : Date()
        dateWasEdited = draft.dateWasEdited
        payee = draft.payee
        note = draft.note
        smartText = draft.smartText
    }

    private func handleRequestedLaunch() {
        guard !dismissAfterSave,
              !isSaving,
              !isScanning,
              requestSequence != 0,
              requestSequence != handledRequestSequence,
              let launchMode else { return }
        handledRequestSequence = requestSequence
        if draftSnapshot.hasTransactionContent {
            // Every external action means “start or focus an entry.” Protect
            // even same-kind drafts: Smart Entry and receipt parsing can
            // otherwise overwrite an unfinished expense in place.
            pendingLaunchMode = launchMode
            isConfirmingDraftSwitch = true
            return
        }
        performLaunch(launchMode)
        onRequestHandled(launchMode)
    }

    private func discardDraftAndLaunch(_ launchMode: QuickLogLaunchMode) {
        amountText = ""
        destinationAmountText = ""
        occurredAt = Date()
        dateWasEdited = false
        payee = ""
        note = ""
        smartText = ""
        smartMessage = nil
        errorMessage = nil
        performLaunch(launchMode)
        selectDefaults()
        model.updateQuickLogDraft(draftSnapshot)
    }

    private func performLaunch(_ launchMode: QuickLogLaunchMode) {
        kind = launchMode.kind

        switch launchMode {
        case .smartEntry:
            isHandlingFocusedLaunch = true
            isAmountFocused = false
            isSmartEntryFocused = true
        case .scanReceipt:
            isHandlingFocusedLaunch = true
            isAmountFocused = false
            isSmartEntryFocused = false
            Task { @MainActor in
                await Task.yield()
                isPresentingReceiptPicker = true
            }
        case .expense, .income, .transfer:
            isHandlingFocusedLaunch = false
            isSmartEntryFocused = false
            isAmountFocused = true
        }
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
    }

    /// `dd/mm` and `mm/dd` cannot be told apart from the digits alone, so the
    /// reader follows whatever order this locale writes dates in.
    private static var localePrefersDayFirst: Bool {
        let format = DateFormatter.dateFormat(
            fromTemplate: "yMd",
            options: 0,
            locale: .current
        ) ?? "d/M/y"
        guard let day = format.firstIndex(of: "d"),
              let month = format.firstIndex(of: "M") else { return true }
        return day < month
    }

    private func applyTypedPhrase() {
        let draft = NaturalLanguageEntryParser.draft(
            from: smartText,
            accounts: model.accounts,
            prefersDayFirst: Self.localePrefersDayFirst
        )
        if apply(draft) {
            smartText = ""
            if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        }
    }

    private func scanReceipt(
        _ item: PhotosPickerItem?,
        generation: Int
    ) async {
        guard let item else { return }
        isScanning = true
        smartMessage = nil
        defer {
            if generation == receiptScanGeneration {
                isScanning = false
                receiptScanTask = nil
                photoItem = nil
            }
        }

        do {
            try Task.checkCancellation()
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReceiptScannerError.unreadableImage
            }
            let lines = try await ReceiptScanner.recognizeLines(inImageData: data)
            try Task.checkCancellation()
            _ = apply(
                ReceiptTextParser.draft(
                    fromLines: lines,
                    prefersDayFirst: Self.localePrefersDayFirst
                )
            )
        } catch is CancellationError {
            return
        } catch {
            smartMessage = error.localizedDescription
        }
    }

    /// Applies whatever the reader was sure about and leaves the rest alone.
    /// Returns false when nothing was recognized, so the caller can keep the
    /// user's input instead of clearing it.
    @discardableResult
    private func apply(_ draft: TransactionDraft) -> Bool {
        guard !draft.isEmpty else {
            smartMessage = String(localized: "quick_log.smart_nothing_found")
            return false
        }

        kind = draft.kind == .income ? .income : .expense
        if let amount = draft.amount {
            amountText = amount.formatted(
                .number.precision(.fractionLength(0...2)).grouping(.never)
            )
        }
        if let parsedDate = draft.occurredAt {
            occurredAt = parsedDate
            dateWasEdited = true
        }
        if let parsedPayee = draft.payee { payee = parsedPayee }
        if let parsedAccount = draft.accountID { accountID = parsedAccount }

        if let parsedCategory = draft.categoryID {
            categoryID = parsedCategory
        } else if let parsedPayee = draft.payee,
                  let learned = CategorySuggester.suggestedCategory(
                      forPayee: parsedPayee,
                      kind: draft.kind == .income ? .income : .expense,
                      entries: model.entries,
                      accounts: model.accounts
                  ) {
            categoryID = learned
        }

        smartMessage = nil
        isAmountFocused = false
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        return true
    }

    /// Fills what is still unset. It must not overwrite a value the user or a
    /// parsed draft already chose, because it also runs when the kind changes.
    private func selectDefaults() {
        if !model.userAccounts.contains(where: { $0.id == accountID }) {
            accountID = model.userAccounts.first?.id
        }
        switch kind {
        case .expense:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryID = model.expenseCategories.first { $0.parentID != nil }?.id
                    ?? model.expenseCategories.first?.id
            }
        case .income:
            if !model.incomeCategories.contains(where: { $0.id == categoryID }) {
                categoryID = model.incomeCategories.first?.id
            }
        case .transfer:
            if !model.userAccounts.contains(where: {
                $0.id == destinationAccountID && $0.id != accountID
            }) {
                destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
            }
        }
        if hasRestoredDraft, !dismissAfterSave {
            model.updateQuickLogDraft(draftSnapshot)
        }
    }

    private func save() async {
        guard !isSaving, canSave else { return }
        guard let amount, let accountID else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let savedEntryID: UUID?
            switch kind {
            case .expense:
                guard let categoryID else { return }
                savedEntryID = try await model.logExpense(
                    amount: amount,
                    accountID: accountID,
                    categoryID: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            case .income:
                guard let categoryID else { return }
                savedEntryID = try await model.logIncome(
                    amount: amount,
                    accountID: accountID,
                    categoryID: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            case .transfer:
                guard let destinationAccountID else { return }
                savedEntryID = try await model.logTransfer(
                    amount: amount,
                    destinationAmount: isForeignCurrencyTransfer ? destinationAmount : nil,
                    sourceAccountID: accountID,
                    destinationAccountID: destinationAccountID,
                    occurredAt: occurredAt,
                    note: note
                )
            }

            completeSuccessfulSave(entryID: savedEntryID)
            if dismissAfterSave {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clears only fields that belong to the transaction just saved. Account,
    /// category, transaction kind, and transfer destination remain selected so
    /// the next routine entry takes only an amount and a tap on Save.
    private func completeSuccessfulSave(entryID: UUID?) {
        amountText = ""
        destinationAmountText = ""
        occurredAt = Date()
        dateWasEdited = false
        payee = ""
        note = ""
        smartText = ""
        smartMessage = nil
        photoItem = nil
        errorMessage = nil
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        successFeedback += 1
        isAmountFocused = isActive

        guard !dismissAfterSave, let entryID else { return }
        withAnimation {
            lastSavedEntryID = entryID
        }

        Task {
            try? await Task.sleep(for: .seconds(6))
            guard lastSavedEntryID == entryID else { return }
            withAnimation {
                lastSavedEntryID = nil
            }
        }
    }

    private func undo(entryID: UUID) async {
        guard lastSavedEntryID == entryID else { return }
        isUndoing = true
        errorMessage = nil
        defer { isUndoing = false }

        do {
            try await model.deleteEntry(id: entryID)
            withAnimation {
                lastSavedEntryID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
