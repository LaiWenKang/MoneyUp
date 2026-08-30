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

struct QuickLogEntryView: View {
    static let receiptSignposter = OSSignposter(
        subsystem: "com.laiwenkang.MoneyUp",
        category: "QuickLogReceipt"
    )

    struct ReceiptScanBaseline: Equatable {
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
    @Environment(AppModel.self) private var model
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

    var amount: Decimal? {
        guard let value = decimalAmount(from: amountText), value > .zero else { return nil }
        if let currency = selectedAccountCurrency,
           !MonetaryInputPolicy.accepts(value, currency: currency) {
            return nil
        }
        return value
    }

    var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    var selectedAccountCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == accountID })?.currency
    }

    var selectedDestinationCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == destinationAccountID })?.currency
    }

    var isForeignCurrencyTransfer: Bool {
        kind == .transfer
            && selectedAccountCurrency != nil
            && selectedDestinationCurrency != nil
            && selectedAccountCurrency != selectedDestinationCurrency
    }

    var destinationAmount: Decimal? {
        guard let value = decimalAmount(from: destinationAmountText), value > .zero else {
            return nil
        }
        if let currency = selectedDestinationCurrency,
           !MonetaryInputPolicy.accepts(value, currency: currency) {
            return nil
        }
        return value
    }

    func monetaryInputError(
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

    var splitRemainder: Decimal? {
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

    var splitLinesAreValid: Bool {
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

    var historicalFXConversion: DerivedValue<HistoricalCurrencyConversion?> {
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

    var canSave: Bool {
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

    var title: LocalizedStringKey {
        dismissAfterSave ? "quick_log.title" : "tab.log"
    }
}
