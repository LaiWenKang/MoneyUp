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

/// A snapshot of the device civil-time context used by user-facing timestamp
/// controls. `Date` remains the stored absolute instant; this context controls
/// only how that instant is displayed and edited. Refresh it when iOS reports a
/// clock or time-zone change so automatic time-zone updates follow the user.
struct UserActionTimeContext: Equatable, Sendable {
    let timeZone: TimeZone

    init(timeZone: TimeZone = .autoupdatingCurrent) {
        self.timeZone = timeZone
    }

    var calendar: Calendar {
        FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: timeZone.identifier
        )
    }

    func displayName(at date: Date) -> String {
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        let sign = offsetSeconds < 0 ? "-" : "+"
        let totalMinutes = abs(offsetSeconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let offset = if offsetSeconds == 0 {
            "GMT"
        } else if minutes == 0 {
            "GMT\(sign)\(hours)"
        } else {
            String(format: "GMT%@%d:%02d", sign, hours, minutes)
        }
        guard let abbreviation = timeZone.abbreviation(for: date),
              abbreviation != offset else { return offset }
        return "\(abbreviation) · \(offset)"
    }
}

private struct UserActionTimeChangeModifier: ViewModifier {
    let perform: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.significantTimeChangeNotification
                )
            ) { _ in perform() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSNotification.Name.NSSystemTimeZoneDidChange
                )
            ) { _ in perform() }
    }
}

extension View {
    func onUserActionTimeChange(
        perform: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(UserActionTimeChangeModifier(perform: perform))
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
    let launchRequest: QuickLogRouteRequest?
    let onRequestHandled: @MainActor (QuickLogRouteRequest) -> Void
    let onNavigate: @MainActor (QuickLogNavigationDestination) -> Void

    var body: some View {
        QuickLogEntryView(
            kind: $kind,
            dismissAfterSave: false,
            isActive: isActive,
            launchRequest: launchRequest,
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
            launchRequest: nil,
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

/// Serializes the two optional Quick Log input paths. A receipt selection may
/// invalidate model assistance only when it can actually begin, while Smart
/// Fill always retires receipt work before starting a new assistance request.
@MainActor
enum QuickLogInputAuthority {
    static func receiptItemThatMayBegin<Item>(
        _ item: Item?,
        isActive: Bool,
        cancelAssistance: () -> Void
    ) -> Item? {
        guard let item, isActive else { return nil }
        cancelAssistance()
        return item
    }

    static func beginSmartFill(
        cancelReceipt: () -> Void,
        cancelAssistance: () -> Void,
        start: () -> Void
    ) {
        cancelReceipt()
        cancelAssistance()
        start()
    }

    static func applyReceiptCategory(
        invalidateAssistance: () -> Void,
        mutation: () -> Void
    ) {
        invalidateAssistance()
        mutation()
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

    static func receiptCategoryIsCompatible(
        _ category: LedgerAccount,
        with kind: QuickLogKind
    ) -> Bool {
        guard !category.isArchived, category.systemRole == nil else {
            return false
        }
        switch kind {
        case .expense, .refund:
            return category.kind == .expense
        case .income:
            return category.kind == .income
        case .transfer:
            return false
        }
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

enum QuickLogFocusScrollPolicy {
    /// SwiftUI publishes focus before the keyboard's final safe-area inset is
    /// stable. Repeating the scroll after the animation keeps the last row and
    /// split memo above the keyboard on compact devices.
    static let layoutSettlingNanoseconds: UInt64 = 360_000_000

    static func target(for focus: QuickLogFieldFocus?) -> QuickLogFieldFocus? {
        focus
    }
}

struct QuickLogEntryView: View {
    static let receiptSignposter = OSSignposter(
        subsystem: "com.laiwenkang.MoneyUp",
        category: "QuickLogReceipt"
    )

    struct ReceiptScanBaseline: Equatable {
        let kind: QuickLogKind
        let amountText: String
        let occurredAt: Date
        let dateWasEdited: Bool
        let payee: String
        let note: String
        let accountID: UUID?
        let categoryID: UUID?
    }

    struct PendingDuplicateReview {
        let queryFingerprint: String
        let match: CaptureDuplicateMatch
        let historyDate: Date?
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) var isVoiceOverEnabled
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(AppModel.self) var model
    @AppStorage(MoneyAmountPrivacy.storageKey)
    var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    @FocusState var focusedField: QuickLogFieldFocus?

    @Binding var kind: QuickLogKind
    let dismissAfterSave: Bool
    let isActive: Bool
    let launchRequest: QuickLogRouteRequest?
    let onRequestHandled: @MainActor (QuickLogRouteRequest) -> Void
    let onNavigate: @MainActor (QuickLogNavigationDestination) -> Void

    @State var amountText = ""
    @State var destinationAmountText = ""
    @State var accountID: UUID?
    @State var destinationAccountID: UUID?
    @State var categoryID: UUID?
    @State var accountWasEdited = false
    @State var categoryWasEdited = false
    @State var occurredAt = Date()
    @State var userActionTimeContext = UserActionTimeContext()
    @State var dateWasEdited = false
    @State var payee = ""
    @State var note = ""
    @State var isSaving = false
    @State var errorMessage: String?
    @State var smartText = ""
    @State var photoItem: PhotosPickerItem?
    @State var isScanning = false
    @State var smartMessage: String?
    @State var lastSavedEntryID: UUID?
    @State var isUndoing = false
    @State var successFeedback = 0
    @State var hasRestoredDraft = false
    @State var handledRequestID: UInt64 = 0
    @State var isPresentingReceiptPicker = false
    @State var isHandlingFocusedLaunch = false
    @State var isConfirmingDraftSwitch = false
    @State var pendingLaunchRequest: QuickLogRouteRequest?
    @State var isShowingOptionalDetails = false
    @State var isAddingCategory = false
    @State var isManagingCategories = false
    @State var receiptScanTask: Task<Void, Never>?
    @State var receiptScanGeneration = 0
    @State var receiptScanBaseline: ReceiptScanBaseline?
    @State var receiptResult: ReceiptParseResult?
    @State var captureSuggestionResult: CaptureSuggestionResult?
    @State var captureSuggestionTask: Task<Void, Never>?
    @State var captureSuggestionGeneration = 0
    @State var onDeviceAssistanceCoordinator = QuickLogAssistanceCoordinator()
    @State var onDeviceAssistanceTask: Task<Void, Never>?
    @State var onDeviceAssistance: QuickLogAssistancePresentation?
    @State var pendingDuplicateReview: PendingDuplicateReview?
    @State var preservesCaptureSuggestionsAcrossNextKindChange = false
    @State var autoAppliedAccountSuggestionID: UUID?
    @State var autoAppliedCategorySuggestionID: UUID?
    @State var splitLines: [QuickLogSplitDraftLine] = []
    @State var selectedAllowanceID: UUID?
    /// Provenance for a draft promoted from the lock-safe capture inbox. This
    /// must survive every edit so AppModel can complete the cross-store
    /// exact-once handoff instead of treating the edited draft as unrelated.
    @State var sourceCaptureID: UUID?
    /// Transient image bytes. They are intentionally absent from QuickLogDraft
    /// and reach persistence only when the user turns on receipt retention.
    @State var receiptAttachmentData: Data?
    @State var retainReceiptAttachment = false
    @State var receiptRetentionMessage: String?

    var amount: Decimal? {
        guard let value = decimalAmount(from: amountText), value > .zero else { return nil }
        if let currency = selectedAccountCurrency,
           !MonetaryInputPolicy.accepts(value, currency: currency) {
            return nil
        }
        return value
    }

    var masksPrimaryAmount: Bool {
        hidesAmounts && focusedField != .amount && !amountText.isEmpty
    }

    var masksDestinationAmount: Bool {
        hidesAmounts
            && focusedField != .destinationAmount
            && !destinationAmountText.isEmpty
    }

    var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    var categoryKind: LedgerAccountKind {
        kind == .income ? .income : .expense
    }

    var captureCalendar: Calendar {
        userActionTimeContext.calendar
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
            return AppLocalization.string("error.invalid_amount")
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
            let transactionIsValid = splitLines.isEmpty
                ? categories.contains { $0.id == categoryID }
                : splitLinesAreValid
            guard transactionIsValid else { return false }
            return kind != .expense
                || selectedAllowanceID == nil
                || selectedAllowanceApplication != nil
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
