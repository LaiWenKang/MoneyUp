import Foundation
import MoneyUpCore
import MoneyUpPersistence

enum SafeUserMessageContext: Sendable {
    case general
    case read
    case write
    case save
    case importData
    case exportData
    case restoreData
    case scan
    case unlock

    var fallbackMessage: String {
        switch self {
        case .general:
            String(localized: "error.generic_safe")
        case .read:
            String(localized: "error.read_failed_safe")
        case .write:
            String(localized: "error.write_failed_safe")
        case .save:
            String(localized: "error.save_failed_safe")
        case .importData:
            String(localized: "error.import_failed_safe")
        case .exportData:
            String(localized: "error.export_failed_safe")
        case .restoreData:
            String(localized: "error.restore_failed_safe")
        case .scan:
            String(localized: "error.scan_failed_safe")
        case .unlock:
            String(localized: "error.unlock_failed_safe")
        }
    }
}

/// The only route from an arbitrary caught error to user-visible text.
///
/// MoneyUp-owned domain errors below have deliberately redacted, bilingual
/// `LocalizedError` conformances. Cocoa, decoding, SQL/Keychain wrappers, and
/// unknown third-party errors are never allowed to contribute their payload,
/// file path, status code, domain, or debug description to the UI.
func safeUserMessage(
    for error: Error,
    context: SafeUserMessageContext = .general
) -> String {
    switch error {
    case is AppModelError,
         is DatabaseKeyStoreError,
         is ReceiptScannerError,
         is LockedCaptureStoreError,
         is PersistenceError,
         is PortableArchiveError,
         is ScheduledTransactionError,
         is TransactionFactoryError,
         is JournalEntryValidationError,
         is BudgetTreeError,
         is DecimalCalculationError,
         is CurrencyCodeError,
         is MoneyError,
         is InvestmentHoldingError,
         is TransactionSplitError,
         is ReceiptAttachmentError,
         is ExchangeRateError,
         is SavingsGoalError,
         is TransactionCSVImportError,
         is CSVImportViewError,
         is DerivedValueIssue:
        error.localizedDescription
    default:
        context.fallbackMessage
    }
}

private enum RecoveryIssueArea: CaseIterable, Hashable {
    case accounts
    case budgets
    case journal
    case schedules
    case holdings
    case receipts
    case other

    func message(count: Int) -> String {
        let format: String
        switch self {
        case .accounts:
            format = String(localized: "recovery.area.accounts")
        case .budgets:
            format = String(localized: "recovery.area.budgets")
        case .journal:
            format = String(localized: "recovery.area.journal")
        case .schedules:
            format = String(localized: "recovery.area.schedules")
        case .holdings:
            format = String(localized: "recovery.area.holdings")
        case .receipts:
            format = String(localized: "recovery.area.receipts")
        case .other:
            format = String(localized: "recovery.area.other")
        }
        return String(format: format, count)
    }
}

/// Converts internal quarantine identities into safe, useful aggregate areas.
/// Raw record IDs remain available to the recovery engine but never cross the
/// presentation boundary.
func safeRecoveryIssueSummaries(_ internalDetails: [String]) -> [String] {
    var counts: [RecoveryIssueArea: Int] = [:]
    for detail in internalDetails {
        let area: RecoveryIssueArea
        if detail.hasPrefix("accounts/") {
            area = .accounts
        } else if detail.hasPrefix("budgets/")
                    || detail.hasPrefix("budget_nodes/") {
            area = .budgets
        } else if detail.hasPrefix("journal_entries/") {
            area = .journal
        } else if detail.hasPrefix("scheduled_transactions/") {
            area = .schedules
        } else if detail.hasPrefix("investment_holdings/") {
            area = .holdings
        } else if detail.hasPrefix("receipt_attachments/") {
            area = .receipts
        } else {
            area = .other
        }
        counts[area, default: 0] += 1
    }
    return RecoveryIssueArea.allCases.compactMap { area in
        counts[area].map { area.message(count: $0) }
    }
}

/// UI-facing descriptions intentionally discard database diagnostics, record
/// identifiers, OS status codes, and enum payloads. Detailed diagnostics stay
/// inside their owning layer and must never be copied into an alert or form.
extension PersistenceError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            String(localized: "error.persistence_update_required")
        case .invalidStoredRecord, .invalidSnapshot, .duplicateSnapshotRecord:
            String(localized: "error.persistence_data_invalid")
        case .invalidKeyLength, .databaseClosed, .databaseFailure,
             .cipherUnavailable, .transactionStateIndeterminate,
             .restoreTransactionStateIndeterminate:
            String(localized: "error.persistence_unavailable")
        }
    }
}

extension ScheduledTransactionError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedKind: String(localized: "schedule.error.unsupported_kind")
        case .amountMustBePositive: String(localized: "schedule.error.positive_amount")
        case .nameCannotBeEmpty: String(localized: "schedule.error.empty_name")
        case .inactive: String(localized: "schedule.error.inactive")
        case .ended: String(localized: "schedule.error.ended")
        case .staleOccurrence: String(localized: "schedule.error.stale_occurrence")
        case .occurrenceAlreadyResolved:
            String(localized: "schedule.error.already_resolved")
        case .linkedEntryRequired:
            String(localized: "schedule.error.linked_entry_required")
        case .unexpectedLinkedEntry:
            String(localized: "schedule.error.unexpected_linked_entry")
        case .cannotAdvance: String(localized: "schedule.error.cannot_advance")
        case .linkedEntryNotFound:
            String(localized: "schedule.error.linked_entry_not_found")
        case .invalidResolutionState:
            String(localized: "schedule.error.invalid_resolution")
        case .invalidLifecycle:
            String(localized: "schedule.error.invalid_lifecycle")
        }
    }
}

extension TransactionFactoryError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .amountMustBePositive:
            String(localized: "error.amount_must_be_positive")
        case .amountMustBeNonZero:
            String(localized: "error.amount_must_be_nonzero")
        case .accountsMustDiffer:
            String(localized: "error.accounts_must_differ")
        case .arithmeticOverflow:
            String(localized: "error.amount_too_large")
        }
    }
}

extension InvestmentHoldingError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .quantityCannotBeNegative, .lotQuantityMustBePositive:
            String(localized: "holding.error.negative_quantity")
        case .priceCannotBeNegative:
            String(localized: "holding.error.negative_price")
        case .insufficientQuantity:
            String(localized: "holding.error.insufficient_quantity")
        case .activityOutOfOrder:
            String(localized: "holding.error.date_out_of_order")
        case .arithmeticOverflow:
            String(localized: "error.amount_too_large")
        case .lotCurrencyMismatch, .valuationCurrencyMismatch:
            String(localized: "holding.error.currency_mismatch")
        case .lotRemainingQuantityInvalid, .lotQuantityMismatch,
             .duplicateIdentifier, .duplicateLinkedEntry, .invalidDisposal,
             .historyMismatch:
            String(localized: "error.invalid_book")
        case .correctionUnavailable:
            String(localized: "holding.error.invalid_trade")
        }
    }
}

extension SavingsGoalError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyName:
            String(localized: "error.empty_name")
        case .nonPositiveTarget, .nonPositiveMovement:
            String(localized: "error.amount_must_be_positive")
        case .currencyMismatch:
            String(localized: "error.balance_currency_mismatch")
        case .withdrawalExceedsBalance:
            String(localized: "goal.error.withdrawal_exceeds_balance")
        case let .unsupportedPrecision(currency):
            String(
                format: String(localized: "error.currency_precision"),
                currency.value,
                currency.minorUnits
            )
        case .calculationFailed:
            String(localized: "error.calculation_unavailable")
        case .targetBeforeCreation, .movementBeforeCreation,
             .resetBeforeCreation, .duplicateMovementID, .duplicateResetID,
             .invalidOriginContext, .invalidDate:
            String(localized: "goal.error.invalid")
        }
    }
}

extension JournalEntryValidationError: @retroactive LocalizedError {
    public var errorDescription: String? {
        String(localized: "error.balance_invalid")
    }
}

extension BudgetTreeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        String(localized: "error.budget_invalid")
    }
}

extension DecimalCalculationError: @retroactive LocalizedError {
    public var errorDescription: String? {
        String(localized: "error.balance_invalid")
    }
}

extension CurrencyCodeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        String(localized: "error.currency_invalid")
    }
}

extension MoneyError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notANumber:
            String(localized: "error.invalid_amount")
        case .currencyMismatch:
            String(localized: "error.balance_currency_mismatch")
        case let .unsupportedPrecision(currency):
            String(
                format: String(localized: "error.currency_precision"),
                currency.value,
                currency.minorUnits
            )
        case .exceedsNewWriteMaximum:
            String(localized: "error.amount_too_large")
        }
    }
}
