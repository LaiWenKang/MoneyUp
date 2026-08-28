import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

enum QuickLogKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case expense
    case income
    case transfer
    case refund

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .expense: "transaction.expense"
        case .income: "transaction.income"
        case .transfer: "transaction.transfer"
        case .refund: "transaction.refund"
        }
    }
}

/// Destinations exposed beside the keyboard while the permanent Log tab has
/// focus. The system tab bar sits behind the iPhone keyboard, so this compact
/// route keeps all four sibling tabs reachable without abandoning the draft.
enum QuickLogNavigationDestination: Hashable, Sendable {
    case today
    case history
    case plan
    case assets
}

/// The permanent, center transaction-entry destination.
///
/// `kind` lives in the tab container so a widget/deep link can both select the
/// Log tab and switch this form to the requested transaction type.
struct LogView: View {
    @Binding var kind: QuickLogKind
    let isActive: Bool
    let launchMode: QuickLogLaunchMode?
    let requestSequence: Int
    let onRequestHandled: @MainActor (QuickLogLaunchMode) -> Void
    let onNavigate: @MainActor (QuickLogNavigationDestination) -> Void

    var body: some View {
        QuickLogEntryView(
            kind: $kind,
            dismissAfterSave: false,
            isActive: isActive,
            launchMode: launchMode,
            requestSequence: requestSequence,
            onRequestHandled: onRequestHandled,
            onNavigate: onNavigate
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
            onRequestHandled: { _ in },
            onNavigate: { _ in }
        )
    }
}

/// Keeps the optional retention copy behind the user-visible recognition
/// result. The callbacks stay main-actor isolated so a generation check and
/// suggestion publication are one atomic UI decision before ImageIO work
/// begins.
@MainActor
enum QuickLogReceiptPipeline {
    static func run<Suggestion: Sendable>(
        recognize: () async throws -> Suggestion?,
        handleSuggestions: (Suggestion) -> Bool,
        handleNoSuggestions: () -> Bool,
        handleRecognitionFailure: (Error) -> Bool,
        prepareRetention: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            let suggestion = try await recognize()
            try Task.checkCancellation()
            if let suggestion {
                guard handleSuggestions(suggestion) else { return }
            } else {
                guard handleNoSuggestions() else { return }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard handleRecognitionFailure(error) else { return }
        }
        try Task.checkCancellation()
        try await prepareRetention()
    }
}

enum QuickLogMotionPolicy {
    static func animatesSavedFeedback(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}

enum QuickLogOccurrencePolicy {
    static func shouldRefresh(
        hasTransactionContent: Bool,
        dateWasEdited: Bool,
        sourceCaptureID: UUID?
    ) -> Bool {
        !hasTransactionContent && !dateWasEdited && sourceCaptureID == nil
    }
}

private struct QuickLogEntryView: View {
    private static let receiptSignposter = OSSignposter(
        subsystem: "com.laiwenkang.MoneyUp",
        category: "QuickLogReceipt"
    )

    private enum FocusedField: Hashable {
        case amount
        case destinationAmount
        case smartEntry
        case payee
        case note
    }

    private struct ReceiptScanBaseline: Equatable {
        let amountText: String
        let occurredAt: Date
        let dateWasEdited: Bool
        let payee: String
        let note: String
        let accountID: UUID?
        let categoryID: UUID?
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @FocusState private var focusedField: FocusedField?

    @Binding var kind: QuickLogKind
    let dismissAfterSave: Bool
    let isActive: Bool
    let launchMode: QuickLogLaunchMode?
    let requestSequence: Int
    let onRequestHandled: @MainActor (QuickLogLaunchMode) -> Void
    let onNavigate: @MainActor (QuickLogNavigationDestination) -> Void

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
    @State private var isShowingOptionalDetails = false
    @State private var receiptScanTask: Task<Void, Never>?
    @State private var receiptScanGeneration = 0
    @State private var receiptScanBaseline: ReceiptScanBaseline?
    @State private var receiptResult: ReceiptParseResult?
    @State private var splitLines: [QuickLogSplitDraftLine] = []
    /// Provenance for a draft promoted from the lock-safe capture inbox. This
    /// must survive every edit so AppModel can complete the cross-store
    /// exact-once handoff instead of treating the edited draft as unrelated.
    @State private var sourceCaptureID: UUID?
    /// Transient image bytes. They are intentionally absent from QuickLogDraft
    /// and reach persistence only when the user turns on receipt retention.
    @State private var receiptAttachmentData: Data?
    @State private var retainReceiptAttachment = false
    @State private var receiptRetentionMessage: String?

    private var amount: Decimal? {
        guard let value = decimalAmount(from: amountText), value > .zero else { return nil }
        if let currency = selectedAccountCurrency,
           !MonetaryInputPolicy.accepts(value, currency: currency) {
            return nil
        }
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
        if let currency = selectedDestinationCurrency,
           !MonetaryInputPolicy.accepts(value, currency: currency) {
            return nil
        }
        return value
    }

    private func monetaryInputError(
        text: String,
        currency: CurrencyCode?
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = decimalAmount(from: trimmed), value > .zero else {
            return String(localized: "error.invalid_amount")
        }
        guard let currency else { return nil }
        do {
            try MonetaryInputPolicy.validate(value, currency: currency)
            return nil
        } catch {
            return safeUserMessage(for: error, context: .save)
        }
    }

    private var splitRemainder: Decimal? {
        guard let amount,
              let currency = selectedAccountCurrency,
              let total = try? Money(amount, currency: currency),
              let lines = try? transactionSplitLines(currency: currency),
              let remainder = try? TransactionSplitCalculator.remainder(
                total: total,
                lines: lines
              ) else { return nil }
        return remainder.amount
    }

    private var splitLinesAreValid: Bool {
        guard let amount,
              let currency = selectedAccountCurrency,
              let total = try? Money(amount, currency: currency),
              let lines = try? transactionSplitLines(currency: currency),
              lines.allSatisfy({ line in
                  categories.contains(where: {
                      $0.id == line.categoryAccountID
                  }) && currency.supports(line.amount.amount)
              }) else { return false }
        do {
            try TransactionSplitCalculator.validate(total: total, lines: lines)
            return true
        } catch {
            return false
        }
    }

    private var historicalFXConversion: DerivedValue<HistoricalCurrencyConversion?> {
        guard isForeignCurrencyTransfer,
              let amount,
              let source = selectedAccountCurrency,
              let destination = selectedDestinationCurrency else {
            return .available(nil)
        }
        do {
            return .available(
                try model.historicalConversion(
                    amount: amount,
                    from: source,
                    to: destination,
                    occurredAt: occurredAt
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "quick-log-historical-conversion",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    private var canSave: Bool {
        guard !isScanning,
              amount != nil,
              let accountID,
              model.userAccounts.contains(where: { $0.id == accountID }) else {
            return false
        }
        switch kind {
        case .expense, .income, .refund:
            return splitLines.isEmpty
                ? categories.contains { $0.id == categoryID }
                : splitLinesAreValid
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
        let historicalFXConversionResult = historicalFXConversion
        NavigationStack {
            Form {
                if dynamicTypeSize.isAccessibilitySize {
                    kindPicker(style: .menu)
                } else {
                    kindPicker(style: .segmented)
                }

                Section {
                    HStack {
                        TextField(
                            "quick_log.amount",
                            text: trackedBinding(
                                $amountText,
                                \.amountText,
                                refreshesOccurrenceDate: true
                            )
                        )
                        .moneyAmountKeyboard(currency: selectedAccountCurrency)
                        .font(.title2.monospacedDigit())
                        .focused($focusedField, equals: .amount)
                        if let currency = selectedAccountCurrency {
                            Text(currency.value)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("transaction.currency")
                                .accessibilityValue(Text(currency.value))
                        }
                    }
                    if let message = monetaryInputError(
                        text: amountText,
                        currency: selectedAccountCurrency
                    ) {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
                    }

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
                                        \.destinationAmountText,
                                        refreshesOccurrenceDate: true
                                    )
                                )
                                .moneyAmountKeyboard(currency: selectedDestinationCurrency)
                                .focused($focusedField, equals: .destinationAmount)
                                if let currency = selectedDestinationCurrency {
                                    Text(currency.value)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let message = monetaryInputError(
                                text: destinationAmountText,
                                currency: selectedDestinationCurrency
                            ) {
                                Label(message, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .accessibilityAddTraits(.isStaticText)
                            }

                            if case let .available(.some(conversion)) =
                                historicalFXConversionResult {
                                Button {
                                    destinationAmountText = editableAmount(
                                        conversion.converted.amount
                                    )
                                    persistUserDraftChange { snapshot in
                                        snapshot.destinationAmountText = destinationAmountText
                                    }
                                } label: {
                                    Label(
                                        String(
                                            format: String(localized: "fx.use_estimate_format"),
                                            conversion.converted.currency.value,
                                            NSDecimalNumber(
                                                decimal: conversion.converted.amount
                                            ).stringValue,
                                            conversion.effectiveDayKey
                                        ),
                                        systemImage: "function"
                                    )
                                }
                                .accessibilityHint("fx.estimate_accessibility_hint")
                            } else if case let .unavailable(issue) =
                                historicalFXConversionResult {
                                DerivedValueUnavailableView(issue: issue)
                            } else {
                                Label("fx.unconverted_mode", systemImage: "equal.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Toggle(
                            "quick_log.split_transaction",
                            isOn: Binding(
                                get: { !splitLines.isEmpty },
                                set: { enabled in
                                    if enabled {
                                        refreshUntouchedOccurrenceDate()
                                    }
                                    if enabled {
                                        let initialCategory = categoryID ?? categories.first?.id
                                        splitLines = [
                                            QuickLogSplitDraftLine(categoryID: initialCategory),
                                            QuickLogSplitDraftLine(categoryID: initialCategory)
                                        ]
                                    } else {
                                        splitLines = []
                                    }
                                    persistUserDraftChange { snapshot in
                                        snapshot.splitLines = splitLines
                                    }
                                }
                            )
                        )

                        if splitLines.isEmpty {
                            Picker(
                                "transaction.category",
                                selection: trackedBinding($categoryID, \.categoryID)
                            ) {
                                ForEach(categories) { category in
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                        } else {
                            splitEditor
                        }
                    }
                }

                if kind != .transfer {
                    smartEntrySection
                }

                Section {
                    DisclosureGroup(
                        "quick_log.optional_details",
                        isExpanded: $isShowingOptionalDetails
                    ) {
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
                                text: trackedBinding(
                                    $payee,
                                    \.payee,
                                    refreshesOccurrenceDate: true
                                )
                            )
                            .focused($focusedField, equals: .payee)
                        }
                        TextField(
                            "quick_log.note",
                            text: trackedBinding(
                                $note,
                                \.note,
                                refreshesOccurrenceDate: true
                            ),
                            axis: .vertical
                        )
                            .lineLimit(2...4)
                            .focused($focusedField, equals: .note)
                    }
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

            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
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
                ToolbarItemGroup(placement: .keyboard) {
                    if !dismissAfterSave {
                        Menu {
                            Button {
                                navigate(to: .today)
                            } label: {
                                Label("tab.today", systemImage: "house.fill")
                            }
                            Button {
                                navigate(to: .history)
                            } label: {
                                Label("tab.history", systemImage: "clock.arrow.circlepath")
                            }
                            Button {
                                navigate(to: .plan)
                            } label: {
                                Label("tab.plan", systemImage: "chart.pie.fill")
                            }
                            Button {
                                navigate(to: .assets)
                            } label: {
                                Label("tab.assets", systemImage: "wallet.bifold.fill")
                            }
                        } label: {
                            Label("quick_log.switch_tab", systemImage: "square.grid.2x2")
                        }
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        Label("action.save", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave || isSaving || isUndoing)

                    Spacer()
                    Button {
                        dismissKeyboard()
                    } label: {
                        Label("action.done", systemImage: "keyboard.chevron.compact.down")
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                restoreDraftIfAvailable()
                selectDefaults()
                hasRestoredDraft = true
                refreshUntouchedOccurrenceDate()
                handleRequestedLaunch()
                Task { @MainActor in
                    await Task.yield()
                    if isActive && amountText.isEmpty && !isHandlingFocusedLaunch {
                        focusedField = .amount
                    }
                }
            }
            .onChange(of: isActive) { _, newValue in
                if !newValue {
                    cancelReceiptProcessing()
                    receiptResult = nil
                    receiptAttachmentData = nil
                    retainReceiptAttachment = false
                    receiptRetentionMessage = nil
                    smartMessage = nil
                    isPresentingReceiptPicker = false
                    dismissKeyboard()
                    isHandlingFocusedLaunch = false
                } else if amountText.isEmpty {
                    refreshUntouchedOccurrenceDate()
                    focusedField = .amount
                }
            }
            .onChange(of: kind) { _, newKind in
                if newKind == .transfer {
                    cancelReceiptProcessing()
                    receiptResult = nil
                    receiptAttachmentData = nil
                    retainReceiptAttachment = false
                    receiptRetentionMessage = nil
                    splitLines = []
                }
                selectDefaults()
                if newKind != .transfer, !splitLines.isEmpty {
                    for index in splitLines.indices where !categories.contains(
                        where: { $0.id == splitLines[index].categoryID }
                    ) {
                        splitLines[index].categoryID = categories.first?.id
                    }
                }
                persistUserDraftChange { $0.splitLines = splitLines }
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
                guard let item, isActive else {
                    receiptScanTask = nil
                    receiptScanBaseline = nil
                    if !isActive {
                        photoItem = nil
                        receiptResult = nil
                        receiptAttachmentData = nil
                        retainReceiptAttachment = false
                        receiptRetentionMessage = nil
                        smartMessage = nil
                        isScanning = false
                    }
                    return
                }
                refreshUntouchedOccurrenceDate()
                receiptScanBaseline = ReceiptScanBaseline(
                    amountText: amountText,
                    occurredAt: occurredAt,
                    dateWasEdited: dateWasEdited,
                    payee: payee,
                    note: note,
                    accountID: accountID,
                    categoryID: categoryID
                )
                isScanning = true
                smartMessage = nil
                receiptResult = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                receiptScanTask = Task { @MainActor in
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
                cancelReceiptProcessing()
                receiptScanTask = nil
                photoItem = nil
                receiptResult = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                smartMessage = nil
                isPresentingReceiptPicker = false
            }
            .scrollDismissesKeyboard(.interactively)
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
                    Button {
                        updateSavedEntry(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("action.close")
                    .disabled(isUndoing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(
                    QuickLogMotionPolicy.animatesSavedFeedback(
                        reduceMotion: accessibilityReduceMotion
                    )
                        ? .move(edge: .bottom).combined(with: .opacity)
                        : .identity
                )
            } else {
                Button {
                    Task { await save() }
                } label: {
                    Label("action.save", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.moneyUpAction)
                .disabled(!canSave || isSaving || isUndoing)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
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
                focusedField = .amount
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
        .alert("error.could_not_save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("action.okay", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private var smartEntrySection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                TextField(
                    "quick_log.smart_placeholder",
                    text: trackedBinding(
                        $smartText,
                        \.smartText,
                        refreshesOccurrenceDate: true
                    ),
                    axis: .vertical
                )
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .smartEntry)
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

            if let receiptResult {
                receiptSuggestions(receiptResult)
            }

            if receiptAttachmentData != nil {
                Toggle("quick_log.keep_receipt", isOn: $retainReceiptAttachment)
                    .accessibilityHint("quick_log.keep_receipt_hint")
                Text("quick_log.keep_receipt_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let receiptRetentionMessage {
                Text(receiptRetentionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("quick_log.smart_entry")
        } footer: {
            Text("quick_log.smart_footer")
        }
    }

    private func kindPicker<Style: PickerStyle>(style: Style) -> some View {
        Picker(
            "transaction.kind",
            selection: trackedBinding($kind, \.kind)
        ) {
            ForEach(QuickLogKind.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(style)
    }

    @ViewBuilder
    private var splitEditor: some View {
        ForEach(splitLines.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "quick_log.split_category",
                    selection: Binding(
                        get: { splitLines[index].categoryID },
                        set: { value in
                            splitLines[index].categoryID = value
                            persistUserDraftChange { $0.splitLines = splitLines }
                        }
                    )
                ) {
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }

                HStack {
                    TextField(
                        "quick_log.split_amount",
                        text: Binding(
                            get: { splitLines[index].amountText },
                            set: { value in
                                splitLines[index].amountText = value
                                persistUserDraftChange { $0.splitLines = splitLines }
                            }
                        )
                    )
                    .moneyAmountKeyboard(currency: selectedAccountCurrency)
                    .accessibilityLabel("quick_log.split_amount")
                    if let currency = selectedAccountCurrency {
                        Text(currency.value).foregroundStyle(.secondary)
                    }
                    if splitLines.count > 2 {
                        Button(role: .destructive) {
                            splitLines.remove(at: index)
                            persistUserDraftChange { $0.splitLines = splitLines }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("quick_log.split_remove")
                    }
                }
                if let message = monetaryInputError(
                    text: splitLines[index].amountText,
                    currency: selectedAccountCurrency
                ) {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityAddTraits(.isStaticText)
                }

                TextField(
                    "quick_log.split_memo",
                    text: Binding(
                        get: { splitLines[index].memo },
                        set: { value in
                            splitLines[index].memo = value
                            persistUserDraftChange { $0.splitLines = splitLines }
                        }
                    )
                )
                .font(.caption)
            }
            .padding(.vertical, 4)
        }

        Button {
            splitLines.append(
                QuickLogSplitDraftLine(categoryID: categoryID ?? categories.first?.id)
            )
            persistUserDraftChange { $0.splitLines = splitLines }
        } label: {
            Label("quick_log.split_add", systemImage: "plus.circle")
        }
        .disabled(splitLines.count >= QuickLogDraft.maximumSplitLineCount)

        if let remainder = splitRemainder, let currency = selectedAccountCurrency {
            LabeledContent("quick_log.split_remainder") {
                Text("\(editableAmount(remainder)) \(currency.value)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(remainder == .zero ? Color.green : Color.red)
            }
            .accessibilityHint(
                remainder == .zero
                    ? Text("quick_log.split_balanced")
                    : Text("quick_log.split_not_balanced")
            )
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
            smartText: smartText,
            splitLines: splitLines,
            sourceCaptureID: sourceCaptureID
        )
    }

    /// Writes direct control edits to the model in the same setter that updates
    /// SwiftUI state. The app-level background callback can therefore flush the
    /// final keystroke even if SwiftUI has not delivered `onChange` yet.
    private func trackedBinding<Value>(
        _ binding: Binding<Value>,
        _ keyPath: WritableKeyPath<QuickLogDraft, Value>,
        refreshesOccurrenceDate: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if refreshesOccurrenceDate {
                    refreshUntouchedOccurrenceDate(persist: false)
                }
                binding.wrappedValue = newValue
                persistUserDraftChange { snapshot in
                    snapshot[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func refreshUntouchedOccurrenceDate(persist: Bool = true) {
        guard hasRestoredDraft,
              !dismissAfterSave,
              QuickLogOccurrencePolicy.shouldRefresh(
                  hasTransactionContent: draftSnapshot.hasTransactionContent,
                  dateWasEdited: dateWasEdited,
                  sourceCaptureID: sourceCaptureID
              ) else { return }
        occurredAt = model.currentDateForUserAction()
        if persist {
            model.updateQuickLogDraft(draftSnapshot)
        }
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
        applyDraft(draft)
    }

    private func applyDraft(_ draft: QuickLogDraft) {
        kind = draft.kind
        amountText = draft.amountText
        destinationAmountText = draft.destinationAmountText
        accountID = draft.accountID
        destinationAccountID = draft.destinationAccountID
        categoryID = draft.categoryID
        occurredAt = draft.hasTransactionContent
            ? draft.occurredAt : model.currentDateForUserAction()
        dateWasEdited = draft.dateWasEdited
        payee = draft.payee
        note = draft.note
        smartText = draft.smartText
        splitLines = draft.splitLines
        sourceCaptureID = draft.sourceCaptureID
        isShowingOptionalDetails = draft.dateWasEdited
            || !draft.payee.isEmpty
            || !draft.note.isEmpty
    }

    private func handleRequestedLaunch() {
        guard !dismissAfterSave,
              !isSaving,
              !isScanning,
              requestSequence != 0,
              requestSequence != handledRequestSequence,
              let launchMode else { return }
        handledRequestSequence = requestSequence
        if sourceCaptureID != nil {
            // Unlock promotion itself routes to Log. It is the same durable
            // draft, not a request to discard it and start another entry.
            onRequestHandled(launchMode)
            focusedField = .amount
            return
        }
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
        cancelReceiptProcessing()
        amountText = ""
        destinationAmountText = ""
        occurredAt = model.currentDateForUserAction()
        dateWasEdited = false
        payee = ""
        note = ""
        smartText = ""
        smartMessage = nil
        receiptResult = nil
        splitLines = []
        sourceCaptureID = nil
        receiptAttachmentData = nil
        retainReceiptAttachment = false
        receiptRetentionMessage = nil
        errorMessage = nil
        performLaunch(launchMode)
        selectDefaults()
        model.updateQuickLogDraft(draftSnapshot)
    }

    private func performLaunch(_ launchMode: QuickLogLaunchMode) {
        refreshUntouchedOccurrenceDate()
        kind = launchMode.kind

        switch launchMode {
        case .smartEntry:
            isHandlingFocusedLaunch = true
            focusedField = .smartEntry
        case .scanReceipt:
            isHandlingFocusedLaunch = true
            dismissKeyboard()
            Task { @MainActor in
                await Task.yield()
                isPresentingReceiptPicker = true
            }
        case .expense, .income, .transfer, .refund:
            isHandlingFocusedLaunch = false
            focusedField = .amount
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
        receiptResult = nil
        let draft = NaturalLanguageEntryParser.draft(
            from: smartText,
            accounts: model.accounts,
            now: model.currentDateForUserAction(),
            calendar: model.reportingCalendar,
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
        let suggestionsSignpostID = Self.receiptSignposter.makeSignpostID()
        let suggestionsInterval = Self.receiptSignposter.beginInterval(
            "Receipt selection to suggestions",
            id: suggestionsSignpostID
        )
        var suggestionsIntervalEnded = false
        defer {
            if !suggestionsIntervalEnded {
                Self.receiptSignposter.endInterval(
                    "Receipt selection to suggestions",
                    suggestionsInterval,
                    "outcome=incomplete"
                )
            }
            if generation == receiptScanGeneration {
                isScanning = false
                receiptScanTask = nil
                receiptScanBaseline = nil
                photoItem = nil
            }
        }
        guard !Task.isCancelled,
              generation == receiptScanGeneration else { return }
        isScanning = true
        smartMessage = nil
        receiptResult = nil
        receiptAttachmentData = nil
        retainReceiptAttachment = false
        receiptRetentionMessage = nil

        do {
            try Task.checkCancellation()
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReceiptScannerError.unreadableImage
            }
            try Task.checkCancellation()
            guard generation == receiptScanGeneration else { return }
            try await ReceiptImageSanitizer.waitForPendingPreparation()
            try Task.checkCancellation()
            guard generation == receiptScanGeneration else { return }
            try await QuickLogReceiptPipeline.run {
                try await model.receiptAnalysis(
                    from: data,
                    prefersDayFirst: Self.localePrefersDayFirst
                )
            } handleSuggestions: { result in
                guard generation == receiptScanGeneration else { return false }
                let didApplySuggestions = applyReceipt(result)

                // Saving and editing can resume as soon as the OCR result is
                // handled. The optional attachment remains
                // unavailable until its private copy is ready.
                isScanning = false
                if didApplySuggestions {
                    Self.receiptSignposter.endInterval(
                        "Receipt selection to suggestions",
                        suggestionsInterval,
                        "outcome=ready"
                    )
                } else {
                    Self.receiptSignposter.endInterval(
                        "Receipt selection to suggestions",
                        suggestionsInterval,
                        "outcome=empty"
                    )
                }
                suggestionsIntervalEnded = true
                return true
            } handleNoSuggestions: {
                guard generation == receiptScanGeneration,
                      model.state == .ready else { return false }
                isScanning = false
                Self.receiptSignposter.endInterval(
                    "Receipt selection to suggestions",
                    suggestionsInterval,
                    "outcome=empty"
                )
                suggestionsIntervalEnded = true
                return true
            } handleRecognitionFailure: { error in
                guard generation == receiptScanGeneration else { return false }
                smartMessage = safeUserMessage(for: error, context: .scan)
                isScanning = false
                Self.receiptSignposter.endInterval(
                    "Receipt selection to suggestions",
                    suggestionsInterval,
                    "outcome=failed"
                )
                suggestionsIntervalEnded = true
                return true
            } prepareRetention: {
                let sanitizationSignpostID = Self.receiptSignposter.makeSignpostID()
                let sanitizationInterval = Self.receiptSignposter.beginInterval(
                    "Receipt sanitization",
                    id: sanitizationSignpostID
                )
                defer {
                    Self.receiptSignposter.endInterval(
                        "Receipt sanitization",
                        sanitizationInterval
                    )
                }

                do {
                    let sanitized = try await ReceiptImageSanitizer
                        .prepareForEncryptedStorage(data)
                    try Task.checkCancellation()
                    guard generation == receiptScanGeneration else { return }
                    receiptAttachmentData = sanitized
                    receiptRetentionMessage = nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard generation == receiptScanGeneration else { return }
                    receiptAttachmentData = nil
                    receiptRetentionMessage = safeUserMessage(
                        for: error,
                        context: .scan
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == receiptScanGeneration else { return }
            smartMessage = safeUserMessage(for: error, context: .scan)
        }
    }

    /// Receipt fields are suggestions, not an automatic commit. Populate the
    /// best candidates, reveal any filled optional details, and keep the full
    /// ranked result in transient view state so alternatives remain reviewable.
    @discardableResult
    private func applyReceipt(_ result: ReceiptParseResult) -> Bool {
        guard let baseline = receiptScanBaseline else {
            receiptResult = nil
            return false
        }
        guard !result.draft.isEmpty else {
            receiptResult = nil
            smartMessage = String(localized: "quick_log.smart_nothing_found")
            return false
        }

        var reviewDraft = result.draft
        // Suggestions may arrive after the user has corrected a field. Apply
        // only values whose field still matches the scan-start snapshot, and
        // never reinterpret the explicitly selected transaction kind.
        if amountText != baseline.amountText { reviewDraft.amount = nil }
        if occurredAt != baseline.occurredAt
            || dateWasEdited != baseline.dateWasEdited {
            reviewDraft.occurredAt = nil
        }
        if payee != baseline.payee { reviewDraft.payee = nil }
        if accountID != baseline.accountID { reviewDraft.accountID = nil }
        if categoryID != baseline.categoryID {
            reviewDraft.categoryID = nil
        } else if let parsedCategoryID = reviewDraft.categoryID,
                  let category = model.accountsByID[parsedCategoryID],
                  category.kind != (kind == .income ? .income : .expense) {
            reviewDraft.categoryID = nil
        }
        _ = apply(
            reviewDraft,
            preservesKind: true,
            suggestsLearnedCategory: false
        )

        if note == baseline.note,
           note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let noteCandidate = result.noteCandidate {
            note = noteCandidate
        }
        if result.draft.occurredAt != nil
            || result.draft.payee != nil
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isShowingOptionalDetails = true
        }

        receiptResult = result
        smartMessage = nil
        if !dismissAfterSave {
            model.updateQuickLogDraft(draftSnapshot)
        }
        return true
    }

    @ViewBuilder
    private func receiptSuggestions(_ result: ReceiptParseResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("quick_log.scan_ready", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text("quick_log.scan_review")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if result.amountCandidates.count > 1 {
                Text("quick_log.scan_alternative_amounts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(
                            Array(result.amountCandidates.prefix(4).enumerated()),
                            id: \.offset
                        ) { _, candidate in
                            Button {
                                amountText = editableAmount(candidate)
                                persistUserDraftChange { snapshot in
                                    snapshot.amountText = amountText
                                }
                            } label: {
                                if let currency = selectedAccountCurrency {
                                    Text("\(editableAmount(candidate)) \(currency.value)")
                                } else {
                                    Text(editableAmount(candidate))
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Applies whatever the reader was sure about and leaves the rest alone.
    /// Returns false when nothing was recognized, so the caller can keep the
    /// user's input instead of clearing it.
    @discardableResult
    private func apply(
        _ draft: TransactionDraft,
        preservesKind: Bool = false,
        suggestsLearnedCategory: Bool = true
    ) -> Bool {
        guard !draft.isEmpty else {
            smartMessage = String(localized: "quick_log.smart_nothing_found")
            return false
        }

        if !preservesKind {
            switch draft.kind {
            case .expense: kind = .expense
            case .income: kind = .income
            case .refund: kind = .refund
            }
        }
        if let amount = draft.amount {
            amountText = editableAmount(amount)
        }
        if let parsedDate = draft.occurredAt {
            occurredAt = parsedDate
            dateWasEdited = true
        }
        if let parsedPayee = draft.payee { payee = parsedPayee }
        if let parsedAccount = draft.accountID { accountID = parsedAccount }

        if let parsedCategory = draft.categoryID {
            categoryID = parsedCategory
        } else if suggestsLearnedCategory,
                  let parsedPayee = draft.payee,
                  let learned = CategorySuggester.suggestedCategory(
                      forPayee: parsedPayee,
                      kind: draft.kind == .income ? .income : .expense,
                      entries: model.entries,
                      accounts: model.accounts
                  ) {
            categoryID = learned
        }

        smartMessage = nil
        dismissKeyboard()
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        return true
    }

    /// Fills what is still unset. It must not overwrite a value the user or a
    /// parsed draft already chose, because it also runs when the kind changes.
    private func selectDefaults() {
        if !model.userAccounts.contains(where: { $0.id == accountID }) {
            accountID = validPreferred(
                model.profile?.preferredAccountID,
                in: model.userAccounts
            ) ?? recentAccountID() ?? model.userAccounts.first?.id
        }
        switch kind {
        case .expense:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryID = validPreferred(
                    model.profile?.preferredExpenseCategoryID,
                    in: model.expenseCategories
                ) ?? recentCategoryID(kind: .expense)
                    ?? model.expenseCategories.first { $0.parentID != nil }?.id
                    ?? model.expenseCategories.first?.id
            }
        case .income:
            if !model.incomeCategories.contains(where: { $0.id == categoryID }) {
                categoryID = validPreferred(
                    model.profile?.preferredIncomeCategoryID,
                    in: model.incomeCategories
                ) ?? recentCategoryID(kind: .income)
                    ?? model.incomeCategories.first?.id
            }
        case .refund:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryID = validPreferred(
                    model.profile?.preferredExpenseCategoryID,
                    in: model.expenseCategories
                ) ?? recentCategoryID(kind: .expense)
                    ?? model.expenseCategories.first { $0.parentID != nil }?.id
                    ?? model.expenseCategories.first?.id
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

    private func validPreferred(
        _ id: UUID?,
        in choices: [LedgerAccount]
    ) -> UUID? {
        guard let id, choices.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func recentAccountID() -> UUID? {
        // AppModel intentionally retains only the 80 newest valid entries.
        // Defaults favor recent behavior and never trigger a historical scan.
        let validIDs = Set(model.userAccounts.map(\.id))
        return model.entries.lazy
            .filter { entry in
                switch kind {
                case .expense: entry.kind == .expense
                case .income: entry.kind == .income
                case .transfer: entry.kind == .transfer
                case .refund: entry.kind == .expense
                }
            }
            .flatMap(\.postings)
            .first { validIDs.contains($0.accountID) }?
            .accountID
    }

    private func recentCategoryID(kind: LedgerAccountKind) -> UUID? {
        let choices = kind == .income ? model.incomeCategories : model.expenseCategories
        let validIDs = Set(choices.map(\.id))
        let cutoff = model.reportingCalendar.date(
            byAdding: .day,
            value: -30,
            to: Date()
        ) ?? .distantPast
        var counts: [UUID: Int] = [:]
        var firstSeenOrder: [UUID: Int] = [:]

        for (index, entry) in model.entries.enumerated() where entry.occurredAt >= cutoff {
            guard accountID == nil || entry.postings.contains(where: { $0.accountID == accountID })
            else { continue }
            for posting in entry.postings where validIDs.contains(posting.accountID) {
                counts[posting.accountID, default: 0] += 1
                firstSeenOrder[posting.accountID] = firstSeenOrder[posting.accountID] ?? index
            }
        }
        return counts.keys.max { first, second in
            let firstCount = counts[first, default: 0]
            let secondCount = counts[second, default: 0]
            if firstCount == secondCount {
                return firstSeenOrder[first, default: .max]
                    > firstSeenOrder[second, default: .max]
            }
            return firstCount < secondCount
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
            let retainedReceipt = retainReceiptAttachment ? receiptAttachmentData : nil
            switch kind {
            case .expense:
                if splitLines.isEmpty {
                    guard let categoryID else { return }
                    savedEntryID = try await model.logExpense(
                        amount: amount,
                        accountID: accountID,
                        categoryID: categoryID,
                        occurredAt: occurredAt,
                        payee: payee,
                        note: note,
                        receiptData: retainedReceipt
                    )
                } else {
                    savedEntryID = try await saveSplit(
                        kind: .expense,
                        amount: amount,
                        accountID: accountID,
                        receiptData: retainedReceipt
                    )
                }
            case .income:
                if splitLines.isEmpty {
                    guard let categoryID else { return }
                    savedEntryID = try await model.logIncome(
                        amount: amount,
                        accountID: accountID,
                        categoryID: categoryID,
                        occurredAt: occurredAt,
                        payee: payee,
                        note: note,
                        receiptData: retainedReceipt
                    )
                } else {
                    savedEntryID = try await saveSplit(
                        kind: .income,
                        amount: amount,
                        accountID: accountID,
                        receiptData: retainedReceipt
                    )
                }
            case .refund:
                if splitLines.isEmpty {
                    guard let categoryID else { return }
                    savedEntryID = try await model.logRefund(
                        amount: amount,
                        accountID: accountID,
                        categoryID: categoryID,
                        occurredAt: occurredAt,
                        payee: payee,
                        note: note,
                        receiptData: retainedReceipt
                    )
                } else {
                    savedEntryID = try await saveSplit(
                        kind: .refund,
                        amount: amount,
                        accountID: accountID,
                        receiptData: retainedReceipt
                    )
                }
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
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func saveSplit(
        kind: QuickLogKind,
        amount: Decimal,
        accountID: UUID,
        receiptData: Data?
    ) async throws -> UUID? {
        guard let currency = selectedAccountCurrency else {
            throw AppModelError.accountHasNoCurrency
        }
        let lines = try transactionSplitLines(currency: currency)
        let total = try Money(amount, currency: currency)
        try TransactionSplitCalculator.validate(total: total, lines: lines)
        return try await model.logSplitTransaction(
            kind: kind,
            amount: amount,
            accountID: accountID,
            lines: lines,
            occurredAt: occurredAt,
            payee: payee,
            note: note,
            receiptData: receiptData
        )
    }

    private func transactionSplitLines(
        currency: CurrencyCode
    ) throws -> [TransactionSplitLine] {
        try splitLines.map { line -> TransactionSplitLine in
            guard let categoryID = line.categoryID,
                  let splitAmount = decimalAmount(from: line.amountText) else {
                throw AppModelError.missingRecord
            }
            return TransactionSplitLine(
                id: line.id,
                categoryAccountID: categoryID,
                amount: try Money(splitAmount, currency: currency),
                memo: line.memo
            )
        }
    }

    /// Clears only fields that belong to the transaction just saved. Account,
    /// category, transaction kind, and transfer destination remain selected so
    /// the next routine entry takes only an amount and a tap on Save.
    private func completeSuccessfulSave(entryID: UUID?) {
        cancelReceiptProcessing()
        if let nextCapture = model.quickLogDraft,
           nextCapture.sourceCaptureID != nil,
           !dismissAfterSave {
            applyDraft(nextCapture)
            selectDefaults()
        } else {
            amountText = ""
            destinationAmountText = ""
            occurredAt = model.currentDateForUserAction()
            dateWasEdited = false
            payee = ""
            note = ""
            smartText = ""
            smartMessage = nil
            receiptResult = nil
            splitLines = []
            sourceCaptureID = nil
            receiptAttachmentData = nil
            retainReceiptAttachment = false
            receiptRetentionMessage = nil
            photoItem = nil
            errorMessage = nil
            isShowingOptionalDetails = false
            if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        }
        successFeedback += 1
        focusedField = isActive ? .amount : nil

        guard !dismissAfterSave, let entryID else { return }
        updateSavedEntry(entryID)
        if isVoiceOverEnabled {
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(String(localized: "quick_log.saved")). \(String(localized: "action.undo"))"
            )
        }

        Task {
            try? await Task.sleep(for: .seconds(6))
            guard lastSavedEntryID == entryID else { return }
            // VoiceOver users dismiss the persistent correction affordance
            // explicitly, so it cannot vanish before they navigate to Undo.
            guard !isVoiceOverEnabled else { return }
            updateSavedEntry(nil)
        }
    }

    private func undo(entryID: UUID) async {
        guard lastSavedEntryID == entryID else { return }
        isUndoing = true
        errorMessage = nil
        defer { isUndoing = false }

        do {
            try await model.deleteEntry(id: entryID)
            updateSavedEntry(nil)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func updateSavedEntry(_ entryID: UUID?) {
        if QuickLogMotionPolicy.animatesSavedFeedback(
            reduceMotion: accessibilityReduceMotion
        ) {
            withAnimation(.snappy(duration: 0.22)) {
                lastSavedEntryID = entryID
            }
        } else {
            lastSavedEntryID = entryID
        }
    }

    /// Invalidates every late receipt callback before clearing UI state. The
    /// sanitizer's shared serial actor owns the no-overlap boundary even after
    /// this view releases its task handle.
    private func cancelReceiptProcessing() {
        receiptScanGeneration &+= 1
        receiptScanTask?.cancel()
        receiptScanTask = nil
        receiptScanBaseline = nil
        isScanning = false
        photoItem = nil
    }

    /// Decimal pads have no return key. Keeping dismissal entirely focus-driven
    /// also makes leaving Log a pure UI action: no transaction is saved and the
    /// unfinished draft is neither cleared nor reinterpreted as completed.
    private func dismissKeyboard() {
        focusedField = nil
    }

    /// A tab change is a navigation action only. Persist the exact current
    /// draft, resign focus, then let the parent select the requested tab.
    private func navigate(to destination: QuickLogNavigationDestination) {
        dismissKeyboard()
        if !dismissAfterSave {
            model.updateQuickLogDraft(draftSnapshot)
        }
        onNavigate(destination)
    }
}
