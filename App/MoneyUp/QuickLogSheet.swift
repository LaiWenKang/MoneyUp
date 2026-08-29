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
    case history(Date?)
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

enum QuickLogSuggestionPolicy {
    static func shouldPrefillReceiptCandidate(
        confidence: CaptureConfidence?,
        fieldIsUnchanged: Bool
    ) -> Bool {
        fieldIsUnchanged && confidence != nil && confidence != .low
    }

    static func shouldPrefillHistorySuggestion(
        confidence: CaptureConfidence,
        fieldWasEdited: Bool,
        parserSuppliedValue: Bool,
        hasFixedDefault: Bool = false,
        usedPayeeHistory: Bool = true
    ) -> Bool {
        confidence == .high
            && !fieldWasEdited
            && !parserSuppliedValue
            && !hasFixedDefault
            && usedPayeeHistory
    }

    static func receiptContextIsCurrent(
        scannedKind: QuickLogKind,
        currentKind: QuickLogKind
    ) -> Bool {
        scannedKind == currentKind
    }
}

enum QuickLogDuplicateReviewPolicy {
    static func historyDate(
        for entry: JournalEntry,
        calendar: Calendar
    ) -> Date {
        entry.originContext.attributedDate(in: calendar) ?? entry.occurredAt
    }
}

enum QuickLogFieldFocus: Hashable {
    case amount
    case destinationAmount
    case smartEntry
    case payee
    case note
    case splitAmount(UUID)
    case splitMemo(UUID)

    var splitLineID: UUID? {
        switch self {
        case let .splitAmount(id), let .splitMemo(id):
            return id
        case .amount, .destinationAmount, .smartEntry, .payee, .note:
            return nil
        }
    }
}

private struct QuickLogEntryView: View {
    private static let receiptSignposter = OSSignposter(
        subsystem: "com.laiwenkang.MoneyUp",
        category: "QuickLogReceipt"
    )

    private struct ReceiptScanBaseline: Equatable {
        let kind: QuickLogKind
        let amountText: String
        let occurredAt: Date
        let dateWasEdited: Bool
        let payee: String
        let note: String
        let accountID: UUID?
        let categoryID: UUID?
    }

    private struct PendingDuplicateReview {
        let queryFingerprint: String
        let match: CaptureDuplicateMatch
        let historyDate: Date?
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @FocusState private var focusedField: QuickLogFieldFocus?

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
    @State private var accountWasEdited = false
    @State private var categoryWasEdited = false
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
    @State private var captureSuggestionResult: CaptureSuggestionResult?
    @State private var pendingDuplicateReview: PendingDuplicateReview?
    @State private var preservesCaptureSuggestionsAcrossNextKindChange = false
    @State private var autoAppliedAccountSuggestionID: UUID?
    @State private var autoAppliedCategorySuggestionID: UUID?
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
                        selection: trackedBinding(
                            $accountID,
                            \.accountID,
                            onUserEdit: {
                                accountWasEdited = true
                                autoAppliedAccountSuggestionID = nil
                                invalidateCaptureSuggestions(
                                    preservingAccount: true
                                )
                            }
                        )
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
                                        clearSplitFocus()
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
                                selection: trackedBinding(
                                    $categoryID,
                                    \.categoryID,
                                    onUserEdit: {
                                        categoryWasEdited = true
                                        autoAppliedCategorySuggestionID = nil
                                    }
                                )
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
                                    invalidateCaptureSuggestions()
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
                                    refreshesOccurrenceDate: true,
                                    onUserEdit: {
                                        invalidateCaptureSuggestions()
                                    }
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
                                navigate(to: .history(nil))
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
                        Task { await attemptSave() }
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
                    pendingDuplicateReview = nil
                    receiptAttachmentData = nil
                    retainReceiptAttachment = false
                    receiptRetentionMessage = nil
                    isPresentingReceiptPicker = false
                    dismissKeyboard()
                    isHandlingFocusedLaunch = false
                } else if amountText.isEmpty {
                    refreshUntouchedOccurrenceDate()
                    focusedField = .amount
                }
            }
            .onChange(of: kind) { _, newKind in
                if preservesCaptureSuggestionsAcrossNextKindChange {
                    preservesCaptureSuggestionsAcrossNextKindChange = false
                } else {
                    invalidateCaptureSuggestions(restoresDefaults: false)
                }
                pendingDuplicateReview = nil
                cancelReceiptProcessing()
                receiptResult = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                if newKind == .transfer {
                    clearSplitFocus()
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
                        receiptAttachmentData = nil
                        retainReceiptAttachment = false
                        receiptRetentionMessage = nil
                        isScanning = false
                    }
                    return
                }
                refreshUntouchedOccurrenceDate()
                receiptScanBaseline = ReceiptScanBaseline(
                    kind: kind,
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
                invalidateCaptureSuggestions()
                pendingDuplicateReview = nil
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
                pendingDuplicateReview = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
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
                    Task { await attemptSave() }
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
        .confirmationDialog(
            "quick_log.duplicate_title",
            isPresented: Binding(
                get: { pendingDuplicateReview != nil },
                set: { if !$0 { pendingDuplicateReview = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("quick_log.duplicate_save_anyway") {
                guard let pending = pendingDuplicateReview else { return }
                pendingDuplicateReview = nil
                Task { await confirmDuplicateSave(pending) }
            }
            Button("quick_log.duplicate_review") {
                let matchDate = pendingDuplicateReview?.historyDate
                pendingDuplicateReview = nil
                if dismissAfterSave {
                    dismiss()
                } else {
                    navigate(to: .history(matchDate))
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingDuplicateReview = nil
            }
        } message: {
            Text(duplicateReviewMessage)
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

            if let captureSuggestionResult,
               captureSuggestionResult.accountSuggestion != nil
                || (splitLines.isEmpty
                    && captureSuggestionResult.categorySuggestion != nil) {
                captureSuggestions(captureSuggestionResult)
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
        ForEach(Array(splitLines.enumerated()), id: \.element.id) { index, line in
            let lineID = line.id
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "quick_log.split_category",
                    selection: Binding(
                        get: {
                            splitLines.first(where: { $0.id == lineID })?.categoryID
                        },
                        set: { value in
                            updateSplitLine(lineID) { $0.categoryID = value }
                        }
                    )
                ) {
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                .accessibilityLabel(
                    Text(
                        String(
                            format: String(localized: "quick_log.split_category_numbered"),
                            index + 1
                        )
                    )
                )

                HStack {
                    TextField(
                        "quick_log.split_amount",
                        text: Binding(
                            get: {
                                splitLines.first(where: { $0.id == lineID })?.amountText
                                    ?? ""
                            },
                            set: { value in
                                updateSplitLine(lineID) { $0.amountText = value }
                            }
                        )
                    )
                    .moneyAmountKeyboard(currency: selectedAccountCurrency)
                    .focused($focusedField, equals: .splitAmount(lineID))
                    .accessibilityLabel(
                        Text(
                            String(
                                format: String(localized: "quick_log.split_amount_numbered"),
                                index + 1
                            )
                        )
                    )
                    if let currency = selectedAccountCurrency {
                        Text(currency.value).foregroundStyle(.secondary)
                    }
                    if splitLines.count > 2 {
                        Button(role: .destructive) {
                            removeSplitLine(lineID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(
                            Text(
                                String(
                                    format: String(
                                        localized: "quick_log.split_remove_numbered"
                                    ),
                                    index + 1
                                )
                            )
                        )
                    }
                }
                if let message = monetaryInputError(
                    text: line.amountText,
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
                        get: {
                            splitLines.first(where: { $0.id == lineID })?.memo ?? ""
                        },
                        set: { value in
                            updateSplitLine(lineID) { $0.memo = value }
                        }
                    )
                )
                .font(.caption)
                .focused($focusedField, equals: .splitMemo(lineID))
                .accessibilityLabel(
                    Text(
                        String(
                            format: String(localized: "quick_log.split_memo_numbered"),
                            index + 1
                        )
                    )
                )
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

    private func updateSplitLine(
        _ lineID: UUID,
        update: (inout QuickLogSplitDraftLine) -> Void
    ) {
        guard let index = splitLines.firstIndex(where: { $0.id == lineID }) else {
            return
        }
        update(&splitLines[index])
        persistUserDraftChange { $0.splitLines = splitLines }
    }

    private func removeSplitLine(_ lineID: UUID) {
        clearSplitFocus(for: lineID)
        splitLines.removeAll { $0.id == lineID }
        persistUserDraftChange { $0.splitLines = splitLines }
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
        refreshesOccurrenceDate: Bool = false,
        onUserEdit: @escaping () -> Void = {}
    ) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if refreshesOccurrenceDate {
                    refreshUntouchedOccurrenceDate(persist: false)
                }
                binding.wrappedValue = newValue
                onUserEdit()
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
        if hasRestoredDraft, draft == draftSnapshot { return }
        if hasRestoredDraft {
            clearPerTransactionReviewState()
        }
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
        accountWasEdited = draft.accountID != nil
        categoryWasEdited = draft.categoryID != nil
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
        accountWasEdited = false
        categoryWasEdited = false
        amountText = ""
        destinationAmountText = ""
        occurredAt = model.currentDateForUserAction()
        dateWasEdited = false
        payee = ""
        note = ""
        smartText = ""
        smartMessage = nil
        receiptResult = nil
        captureSuggestionResult = nil
        autoAppliedAccountSuggestionID = nil
        autoAppliedCategorySuggestionID = nil
        pendingDuplicateReview = nil
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
        invalidateCaptureSuggestions()
        pendingDuplicateReview = nil
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
        guard QuickLogSuggestionPolicy.receiptContextIsCurrent(
            scannedKind: baseline.kind,
            currentKind: kind
        ) else {
            receiptResult = nil
            smartMessage = String(localized: "quick_log.scan_context_changed")
            return false
        }
        guard !result.draft.isEmpty else {
            receiptResult = nil
            smartMessage = String(localized: "quick_log.smart_nothing_found")
            return false
        }

        var reviewDraft = result.draft
        if !QuickLogSuggestionPolicy.shouldPrefillReceiptCandidate(
            confidence: result.amountCandidateDetails.first?.confidence,
            fieldIsUnchanged: amountText == baseline.amountText
                && accountID == baseline.accountID
        ) {
            reviewDraft.amount = nil
        }
        if !QuickLogSuggestionPolicy.shouldPrefillReceiptCandidate(
            confidence: result.merchantCandidateDetails.first?.confidence,
            fieldIsUnchanged: payee == baseline.payee
        ) {
            reviewDraft.payee = nil
        }
        if !QuickLogSuggestionPolicy.shouldPrefillReceiptCandidate(
            confidence: result.dateCandidateDetails.first?.confidence,
            fieldIsUnchanged: occurredAt == baseline.occurredAt
                && dateWasEdited == baseline.dateWasEdited
        ) {
            reviewDraft.occurredAt = nil
        }
        if !QuickLogSuggestionPolicy.shouldPrefillReceiptCandidate(
            confidence: result.categoryCandidateDetails.first?.confidence,
            fieldIsUnchanged: splitLines.isEmpty
                && categoryID == baseline.categoryID
        ) {
            reviewDraft.categoryID = nil
        }
        // Suggestions may arrive after the user has corrected a field. Apply
        // only values whose field still matches the scan-start snapshot, and
        // never reinterpret the explicitly selected transaction kind.
        if accountID != baseline.accountID { reviewDraft.accountID = nil }
        if let parsedCategoryID = reviewDraft.categoryID,
           let category = model.accountsByID[parsedCategoryID],
           category.kind != (kind == .income ? .income : .expense) {
            reviewDraft.categoryID = nil
        }
        _ = apply(
            reviewDraft,
            preservesKind: true,
            suggestsLearnedCategory: true
        )

        if note == baseline.note,
           note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let overallConfidence = result.overallConfidence,
           overallConfidence != .low,
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

            if let confidence = result.overallConfidence {
                Label(
                    captureConfidenceText(confidence),
                    systemImage: confidence == .low
                        ? "questionmark.circle" : "checkmark.seal"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            if !result.amountCandidateDetails.isEmpty {
                Text("quick_log.scan_amount_candidates")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(
                            Array(result.amountCandidateDetails.prefix(4).enumerated()),
                            id: \.offset
                        ) { _, candidate in
                            Button {
                                amountText = editableAmount(candidate.value)
                                persistUserDraftChange { snapshot in
                                    snapshot.amountText = amountText
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let currency = selectedAccountCurrency {
                                        Text("\(editableAmount(candidate.value)) \(currency.value)")
                                            .font(.body.monospacedDigit())
                                        Text("quick_log.scan_amount_account_currency")
                                            .font(.caption2)
                                    } else {
                                        Text(editableAmount(candidate.value))
                                            .font(.body.monospacedDigit())
                                    }
                                    Text(receiptCandidateDetail(candidate))
                                        .font(.caption2)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if !result.merchantCandidateDetails.isEmpty {
                Text("quick_log.scan_merchant_candidates")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(
                            Array(result.merchantCandidateDetails.prefix(3).enumerated()),
                            id: \.offset
                        ) { _, candidate in
                            Button {
                                invalidateCaptureSuggestions()
                                payee = candidate.value
                                isShowingOptionalDetails = true
                                persistUserDraftChange { $0.payee = candidate.value }
                                refreshCaptureSuggestions(
                                    for: TransactionDraft(
                                        kind: kind == .income ? .income
                                            : kind == .refund ? .refund : .expense,
                                        payee: candidate.value,
                                        source: .receipt
                                    )
                                )
                                if !dismissAfterSave {
                                    model.updateQuickLogDraft(draftSnapshot)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.value)
                                    Text(receiptCandidateDetail(candidate))
                                        .font(.caption2)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if !result.dateCandidateDetails.isEmpty {
                Text("quick_log.scan_date_candidates")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(
                            Array(result.dateCandidateDetails.prefix(3).enumerated()),
                            id: \.offset
                        ) { _, candidate in
                            Button {
                                occurredAt = candidate.value
                                dateWasEdited = true
                                invalidateCaptureSuggestions()
                                isShowingOptionalDetails = true
                                persistUserDraftChange { snapshot in
                                    snapshot.occurredAt = candidate.value
                                    snapshot.dateWasEdited = true
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.value.formattedForReporting(
                                        .dateTime.year().month(.abbreviated).day(),
                                        calendar: model.reportingCalendar
                                    ))
                                    Text(receiptCandidateDetail(candidate))
                                        .font(.caption2)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if splitLines.isEmpty,
               let categoryID = result.draft.categoryID,
               let category = model.accountsByID[categoryID],
               let candidate = result.categoryCandidateDetails.first {
                Text("quick_log.scan_category_candidate")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    self.categoryID = categoryID
                    categoryWasEdited = true
                    autoAppliedCategorySuggestionID = nil
                    persistUserDraftChange { $0.categoryID = categoryID }
                } label: {
                    HStack {
                        Text(category.name)
                        Spacer(minLength: 8)
                        Text(receiptCandidateDetail(candidate))
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func receiptCandidateDetail<Value>(
        _ candidate: ReceiptCandidate<Value>
    ) -> String where Value: Equatable & Sendable {
        "\(captureConfidenceText(candidate.confidence)) · "
            + receiptEvidenceText(candidate.evidence)
    }

    private func receiptEvidenceText(_ evidence: [ReceiptCandidateEvidence]) -> String {
        if evidence.contains(.lowOCRConfidence) {
            return String(localized: "quick_log.scan_reason_low_ocr")
        }
        if evidence.contains(.payableAmountLabel)
            || evidence.contains(.precedingPayableAmountLabel) {
            return String(localized: "quick_log.scan_reason_total_label")
        }
        if evidence.contains(.explicitMerchantLabel)
            || evidence.contains(.businessNameMarker)
            || evidence.contains(.receiptHeaderPosition) {
            return String(localized: "quick_log.scan_reason_merchant")
        }
        if evidence.contains(.transactionDateLabel)
            || evidence.contains(.genericDateLabel)
            || evidence.contains(.timeComponent) {
            return String(localized: "quick_log.scan_reason_date")
        }
        if evidence.contains(.categoryKeywordMatch)
            || evidence.contains(.multipleCategoryKeywordMatches) {
            return String(localized: "quick_log.scan_reason_category")
        }
        if evidence.contains(.currencyMarker)
            || evidence.contains(.fractionalAmount) {
            return String(localized: "quick_log.scan_reason_amount_shape")
        }
        return String(localized: "quick_log.scan_reason_pattern")
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

        invalidateCaptureSuggestions()

        if !preservesKind {
            let parsedKind: QuickLogKind
            switch draft.kind {
            case .expense: parsedKind = .expense
            case .income: parsedKind = .income
            case .refund: parsedKind = .refund
            }
            if parsedKind != kind {
                preservesCaptureSuggestionsAcrossNextKindChange = true
                kind = parsedKind
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
        if let parsedAccount = draft.accountID {
            accountID = parsedAccount
            accountWasEdited = true
        }

        if let parsedCategory = draft.categoryID {
            categoryID = parsedCategory
            categoryWasEdited = true
        }

        if suggestsLearnedCategory {
            refreshCaptureSuggestions(for: draft)
        }

        if draft.source == .naturalLanguage {
            smartMessage = String(localized: "quick_log.smart_review")
        } else {
            smartMessage = nil
        }
        dismissKeyboard()
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        return true
    }

    private func invalidateCaptureSuggestions(
        preservingAccount: Bool = false,
        preservingCategory: Bool = false,
        restoresDefaults: Bool = true
    ) {
        var revertedField = false
        if !preservingAccount,
           let autoAppliedAccountSuggestionID,
           accountID == autoAppliedAccountSuggestionID {
            accountID = nil
            accountWasEdited = false
            revertedField = true
        }
        if !preservingCategory,
           let autoAppliedCategorySuggestionID,
           categoryID == autoAppliedCategorySuggestionID {
            categoryID = nil
            categoryWasEdited = false
            revertedField = true
        }
        autoAppliedAccountSuggestionID = nil
        autoAppliedCategorySuggestionID = nil
        captureSuggestionResult = nil
        if restoresDefaults, revertedField {
            selectDefaults()
        }
    }

    /// Restoring another durable draft removes prior explanation provenance
    /// without changing values that belong to the new draft.
    private func clearCaptureSuggestionProvenance() {
        autoAppliedAccountSuggestionID = nil
        autoAppliedCategorySuggestionID = nil
        captureSuggestionResult = nil
    }

    private func clearPerTransactionReviewState() {
        smartMessage = nil
        receiptResult = nil
        clearCaptureSuggestionProvenance()
        pendingDuplicateReview = nil
        receiptAttachmentData = nil
        retainReceiptAttachment = false
        receiptRetentionMessage = nil
        photoItem = nil
        errorMessage = nil
    }

    private func refreshCaptureSuggestions(for draft: TransactionDraft) {
        guard model.journalRecentEntriesAreCurrent,
              let currency = selectedAccountCurrency else {
            captureSuggestionResult = nil
            return
        }
        let suggestionKind: CaptureIntelligenceKind
        switch draft.kind {
        case .expense: suggestionKind = .expense
        case .income: suggestionKind = .income
        case .refund: suggestionKind = .refund
        }
        let query = CaptureSuggestionQuery(
            kind: suggestionKind,
            payee: draft.payee,
            currency: currency,
            occurredAt: draft.occurredAt ?? occurredAt
        )
        let result = CaptureSuggestionEngine.suggestions(
            for: query,
            entries: model.entries,
            accounts: model.accounts
        )
        captureSuggestionResult = result

        if let suggestion = result.accountSuggestion,
           QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
               confidence: suggestion.confidence,
               fieldWasEdited: accountWasEdited,
               parserSuppliedValue: draft.accountID != nil,
               hasFixedDefault: validPreferred(
                   model.profile?.preferredAccountID,
                   in: model.userAccounts
               ) != nil,
               usedPayeeHistory: suggestion.evidence.usedPayeeHistory
           ),
           model.userAccounts.contains(where: {
               $0.id == suggestion.ledgerAccountID
           }) {
            accountID = suggestion.ledgerAccountID
            autoAppliedAccountSuggestionID = suggestion.ledgerAccountID
        }
        if splitLines.isEmpty,
           let suggestion = result.categorySuggestion,
           QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
               confidence: suggestion.confidence,
               fieldWasEdited: categoryWasEdited,
               parserSuppliedValue: draft.categoryID != nil,
               hasFixedDefault: preferredCategoryIDForCurrentKind != nil,
               usedPayeeHistory: suggestion.evidence.usedPayeeHistory
           ),
           categories.contains(where: {
               $0.id == suggestion.ledgerAccountID
           }) {
            categoryID = suggestion.ledgerAccountID
            autoAppliedCategorySuggestionID = suggestion.ledgerAccountID
        }
    }

    private var preferredCategoryIDForCurrentKind: UUID? {
        switch kind {
        case .income:
            validPreferred(
                model.profile?.preferredIncomeCategoryID,
                in: model.incomeCategories
            )
        case .expense, .refund:
            validPreferred(
                model.profile?.preferredExpenseCategoryID,
                in: model.expenseCategories
            )
        case .transfer:
            nil
        }
    }

    @ViewBuilder
    private func captureSuggestions(_ result: CaptureSuggestionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("quick_log.suggestions_from_recent", systemImage: "lightbulb.max")
                .font(.subheadline.weight(.semibold))

            if let suggestion = result.accountSuggestion,
               let account = model.accountsByID[suggestion.ledgerAccountID] {
                captureSuggestionRow(
                    title: String(localized: "quick_log.suggested_account"),
                    account: account,
                    suggestion: suggestion,
                    isApplied: accountID == account.id
                ) {
                    accountID = account.id
                    accountWasEdited = true
                    autoAppliedAccountSuggestionID = nil
                    persistUserDraftChange { $0.accountID = account.id }
                }
            }

            if splitLines.isEmpty,
               let suggestion = result.categorySuggestion,
               let category = model.accountsByID[suggestion.ledgerAccountID] {
                captureSuggestionRow(
                    title: String(localized: "quick_log.suggested_category"),
                    account: category,
                    suggestion: suggestion,
                    isApplied: categoryID == category.id
                ) {
                    categoryID = category.id
                    categoryWasEdited = true
                    autoAppliedCategorySuggestionID = nil
                    persistUserDraftChange { $0.categoryID = category.id }
                }
            }

            Text("quick_log.suggestions_recent_scope")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func captureSuggestionRow(
        title: String,
        account: LedgerAccount,
        suggestion: CaptureFieldSuggestion,
        isApplied: Bool,
        apply: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.name)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                if isApplied {
                    Label("quick_log.suggestion_applied", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button("quick_log.use_suggestion", action: apply)
                        .buttonStyle(.borderless)
                }
            }
            Text(
                "\(captureConfidenceText(suggestion.confidence)) · "
                    + captureEvidenceText(suggestion.evidence)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func captureConfidenceText(_ confidence: CaptureConfidence) -> String {
        switch confidence {
        case .low: String(localized: "quick_log.confidence_low")
        case .medium: String(localized: "quick_log.confidence_medium")
        case .high: String(localized: "quick_log.confidence_high")
        }
    }

    private func captureEvidenceText(_ evidence: CaptureSuggestionEvidence) -> String {
        let format = evidence.usedPayeeHistory
            ? String(localized: "quick_log.suggestion_payee_evidence_format")
            : String(localized: "quick_log.suggestion_kind_evidence_format")
        let count = String(
            format: format,
            evidence.supportingEntryCount,
            evidence.eligibleEntryCount
        )
        let date = evidence.mostRecentUse.formattedForReporting(
            .dateTime.year().month(.abbreviated).day(),
            calendar: model.reportingCalendar
        )
        return String(
            format: String(localized: "quick_log.suggestion_last_used_format"),
            count,
            date
        )
    }

    /// Fills what is still unset. It must not overwrite a value the user or a
    /// parsed draft already chose, because it also runs when the kind changes.
    private func selectDefaults() {
        if !model.userAccounts.contains(where: { $0.id == accountID }) {
            accountWasEdited = false
            accountID = validPreferred(
                model.profile?.preferredAccountID,
                in: model.userAccounts
            ) ?? recentAccountID() ?? model.userAccounts.first?.id
        }
        switch kind {
        case .expense:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryWasEdited = false
                categoryID = validPreferred(
                    model.profile?.preferredExpenseCategoryID,
                    in: model.expenseCategories
                ) ?? recentCategoryID(kind: .expense)
                    ?? model.expenseCategories.first { $0.parentID != nil }?.id
                    ?? model.expenseCategories.first?.id
            }
        case .income:
            if !model.incomeCategories.contains(where: { $0.id == categoryID }) {
                categoryWasEdited = false
                categoryID = validPreferred(
                    model.profile?.preferredIncomeCategoryID,
                    in: model.incomeCategories
                ) ?? recentCategoryID(kind: .income)
                    ?? model.incomeCategories.first?.id
            }
        case .refund:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryWasEdited = false
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

    private func attemptSave() async {
        guard !isSaving, canSave else { return }
        pendingDuplicateReview = nil
        if model.journalRecentEntriesAreCurrent,
           let query = duplicateQuery() {
            let result = CaptureDuplicateDetector.matches(
                for: query,
                in: model.entries
            )
            if let match = result.matches.first {
                let historyDate = model.entries.first(where: {
                    $0.id == match.entryID
                }).map { entry in
                    QuickLogDuplicateReviewPolicy.historyDate(
                        for: entry,
                        calendar: model.reportingCalendar
                    )
                }
                dismissKeyboard()
                pendingDuplicateReview = PendingDuplicateReview(
                    queryFingerprint: result.queryFingerprint,
                    match: match,
                    historyDate: historyDate
                )
                return
            }
        }
        await commitSave()
    }

    private func confirmDuplicateSave(_ pending: PendingDuplicateReview) async {
        guard duplicateQuery()?.fingerprint == pending.queryFingerprint else {
            await attemptSave()
            return
        }
        await commitSave()
    }

    private var duplicateReviewMessage: String {
        guard let pending = pendingDuplicateReview else {
            return String(localized: "quick_log.duplicate_message_fallback")
        }
        let date = pending.historyDate?.formattedForReporting(
            .dateTime.year().month(.abbreviated).day(),
            calendar: model.reportingCalendar
        ) ?? String(localized: "quick_log.duplicate_recent_time")
        let evidence = pending.match.evidence
        let reason: String
        if evidence.sourceMatched {
            reason = String(localized: "quick_log.duplicate_reason_source")
        } else if evidence.categoryMatched && evidence.descriptorMatched {
            reason = String(localized: "quick_log.duplicate_reason_category_payee")
        } else if evidence.descriptorMatched {
            reason = String(localized: "quick_log.duplicate_reason_payee")
        } else if evidence.categoryMatched {
            reason = String(localized: "quick_log.duplicate_reason_category")
        } else {
            reason = String(localized: "quick_log.duplicate_reason_time")
        }
        return String(
            format: String(localized: "quick_log.duplicate_message_format"),
            date,
            reason,
            captureConfidenceText(pending.match.confidence)
        )
    }

    private func duplicateQuery() -> CaptureDuplicateQuery? {
        guard let amount,
              let accountID,
              let sourceCurrency = selectedAccountCurrency,
              let sourceAmount = try? Money(amount, currency: sourceCurrency) else {
            return nil
        }
        let sourceReference = sourceCaptureID.map {
            CaptureSourceReference(
                system: AppModel.lockedCaptureSourceSystem,
                fingerprint: AppModel.lockedCaptureFingerprint($0)
            )
        }
        do {
            switch kind {
            case .expense:
                return try .expense(
                    amount: sourceAmount,
                    paidFrom: accountID,
                    category: splitLines.isEmpty ? categoryID : nil,
                    occurredAt: occurredAt,
                    payee: payee,
                    sourceReference: sourceReference
                )
            case .income:
                return try .income(
                    amount: sourceAmount,
                    depositedInto: accountID,
                    category: splitLines.isEmpty ? categoryID : nil,
                    occurredAt: occurredAt,
                    payee: payee,
                    sourceReference: sourceReference
                )
            case .refund:
                return try .refund(
                    amount: sourceAmount,
                    returnedTo: accountID,
                    category: splitLines.isEmpty ? categoryID : nil,
                    occurredAt: occurredAt,
                    payee: payee,
                    sourceReference: sourceReference
                )
            case .transfer:
                guard let destinationAccountID,
                      let destinationCurrency = selectedDestinationCurrency else {
                    return nil
                }
                if destinationCurrency == sourceCurrency {
                    return try .transfer(
                        amount: sourceAmount,
                        from: accountID,
                        to: destinationAccountID,
                        occurredAt: occurredAt,
                        note: note,
                        sourceReference: sourceReference
                    )
                }
                guard let destinationAmount,
                      let received = try? Money(
                          destinationAmount,
                          currency: destinationCurrency
                      ),
                      let sourceTrading = model.accounts.first(where: {
                          $0.kind == .trading
                              && $0.systemRole == .foreignExchange
                              && $0.currency == sourceCurrency
                      }),
                      let destinationTrading = model.accounts.first(where: {
                          $0.kind == .trading
                              && $0.systemRole == .foreignExchange
                              && $0.currency == destinationCurrency
                      }) else {
                    // A first FX transfer has no persisted clearing accounts,
                    // so by definition there is no prior matching entry.
                    return nil
                }
                return try .foreignCurrencyTransfer(
                    sourceAmount: sourceAmount,
                    destinationAmount: received,
                    from: accountID,
                    to: destinationAccountID,
                    sourceTradingAccountID: sourceTrading.id,
                    destinationTradingAccountID: destinationTrading.id,
                    occurredAt: occurredAt,
                    note: note,
                    sourceReference: sourceReference
                )
            }
        } catch {
            // Duplicate intelligence is advisory. Existing validation remains
            // authoritative and manual Save never depends on this helper.
            return nil
        }
    }

    private func commitSave() async {
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
            // A queued locked capture is a distinct transaction. Keep its
            // durable draft, but never carry receipt bytes, candidates,
            // advisories, or errors from the capture that just committed.
            clearPerTransactionReviewState()
            applyDraft(nextCapture)
            selectDefaults()
        } else {
            accountWasEdited = false
            categoryWasEdited = false
            amountText = ""
            destinationAmountText = ""
            occurredAt = model.currentDateForUserAction()
            dateWasEdited = false
            payee = ""
            note = ""
            smartText = ""
            smartMessage = nil
            receiptResult = nil
            captureSuggestionResult = nil
            autoAppliedAccountSuggestionID = nil
            autoAppliedCategorySuggestionID = nil
            pendingDuplicateReview = nil
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

    private func clearSplitFocus(for lineID: UUID? = nil) {
        guard let focusedLineID = focusedField?.splitLineID,
              lineID == nil || lineID == focusedLineID else { return }
        focusedField = nil
    }

    /// Decimal pads have no return key. Every Quick Log text field, including
    /// stable split-line identities, participates in this one focus boundary.
    /// Leaving Log remains a pure UI action: no transaction is saved and the
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
