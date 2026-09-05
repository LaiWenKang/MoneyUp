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
            AppLocalization.string("error.generic_safe")
        case .read:
            AppLocalization.string("error.read_failed_safe")
        case .write:
            AppLocalization.string("error.write_failed_safe")
        case .save:
            AppLocalization.string("error.save_failed_safe")
        case .importData:
            AppLocalization.string("error.import_failed_safe")
        case .exportData:
            AppLocalization.string("error.export_failed_safe")
        case .restoreData:
            AppLocalization.string("error.restore_failed_safe")
        case .scan:
            AppLocalization.string("error.scan_failed_safe")
        case .unlock:
            AppLocalization.string("error.unlock_failed_safe")
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
         is LoanPlanError,
         is AllowancePlanError,
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
            format = AppLocalization.string("recovery.area.accounts")
        case .budgets:
            format = AppLocalization.string("recovery.area.budgets")
        case .journal:
            format = AppLocalization.string("recovery.area.journal")
        case .schedules:
            format = AppLocalization.string("recovery.area.schedules")
        case .holdings:
            format = AppLocalization.string("recovery.area.holdings")
        case .receipts:
            format = AppLocalization.string("recovery.area.receipts")
        case .other:
            format = AppLocalization.string("recovery.area.other")
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
            AppLocalization.string("error.persistence_update_required")
        case .invalidStoredRecord, .invalidSnapshot, .duplicateSnapshotRecord:
            AppLocalization.string("error.persistence_data_invalid")
        case .logicalStoreLimitExceeded:
            AppLocalization.string("backup.error.too_large")
        case .invalidKeyLength, .invalidQuery, .databaseClosed, .databaseFailure,
             .cipherUnavailable, .transactionStateIndeterminate,
             .restoreTransactionStateIndeterminate:
            AppLocalization.string("error.persistence_unavailable")
        }
    }
}

extension ScheduledTransactionError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedKind: AppLocalization.string("schedule.error.unsupported_kind")
        case .amountMustBePositive: AppLocalization.string("schedule.error.positive_amount")
        case .nameCannotBeEmpty: AppLocalization.string("schedule.error.empty_name")
        case .inactive: AppLocalization.string("schedule.error.inactive")
        case .ended: AppLocalization.string("schedule.error.ended")
        case .staleOccurrence: AppLocalization.string("schedule.error.stale_occurrence")
        case .occurrenceAlreadyResolved:
            AppLocalization.string("schedule.error.already_resolved")
        case .linkedEntryRequired:
            AppLocalization.string("schedule.error.linked_entry_required")
        case .unexpectedLinkedEntry:
            AppLocalization.string("schedule.error.unexpected_linked_entry")
        case .cannotAdvance: AppLocalization.string("schedule.error.cannot_advance")
        case .linkedEntryNotFound:
            AppLocalization.string("schedule.error.linked_entry_not_found")
        case .invalidResolutionState:
            AppLocalization.string("schedule.error.invalid_resolution")
        case .invalidLifecycle:
            AppLocalization.string("schedule.error.invalid_lifecycle")
        }
    }
}

extension TransactionFactoryError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .amountMustBePositive:
            AppLocalization.string("error.amount_must_be_positive")
        case .amountMustBeNonZero:
            AppLocalization.string("error.amount_must_be_nonzero")
        case .accountsMustDiffer:
            AppLocalization.string("error.accounts_must_differ")
        case .arithmeticOverflow:
            AppLocalization.string("error.amount_too_large")
        case .loanCurrencyMismatch:
            AppLocalization.string("loan.error.currency_mismatch")
        case .invalidLoanPayment:
            AppLocalization.string("loan.error.invalid_payment")
        }
    }
}

extension LoanPlanError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyName: AppLocalization.string("error.empty_name")
        case .principalMustBePositive:
            AppLocalization.string("error.amount_must_be_positive")
        case .invalidAPR: AppLocalization.string("loan.error.invalid_apr")
        case .invalidTerm: AppLocalization.string("loan.error.invalid_term")
        case .currencyMismatch: AppLocalization.string("loan.error.currency_mismatch")
        case .invalidDate, .invalidActivity, .tooManyActivities:
            AppLocalization.string("loan.error.invalid")
        }
    }
}

extension AllowancePlanError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyName: AppLocalization.string("error.empty_name")
        case .amountMustBePositive, .usageAmountMustBePositive:
            AppLocalization.string("error.amount_must_be_positive")
        case .currencyMismatch:
            AppLocalization.string("error.balance_currency_mismatch")
        case .usageExceedsAvailable:
            AppLocalization.string("allowance.error.overuse")
        case .invalidDate, .invalidTimeZone, .invalidRolloverCap,
             .tooManyCategories, .tooManyUsages, .usageBeforeStart, .usageAfterEnd,
             .duplicateLinkedUsage, .invalidPolicyRevision, .duplicateReconciliation:
            AppLocalization.string("allowance.error.invalid")
        }
    }
}

extension InvestmentHoldingError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .quantityCannotBeNegative, .lotQuantityMustBePositive:
            AppLocalization.string("holding.error.negative_quantity")
        case .priceCannotBeNegative:
            AppLocalization.string("holding.error.negative_price")
        case .insufficientQuantity:
            AppLocalization.string("holding.error.insufficient_quantity")
        case .activityOutOfOrder:
            AppLocalization.string("holding.error.date_out_of_order")
        case .arithmeticOverflow:
            AppLocalization.string("error.amount_too_large")
        case .lotCurrencyMismatch, .valuationCurrencyMismatch:
            AppLocalization.string("holding.error.currency_mismatch")
        case .lotRemainingQuantityInvalid, .lotQuantityMismatch,
             .duplicateIdentifier, .duplicateLinkedEntry, .invalidDisposal,
             .historyMismatch:
            AppLocalization.string("error.invalid_book")
        case .correctionUnavailable:
            AppLocalization.string("holding.error.invalid_trade")
        }
    }
}

extension SavingsGoalError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyName:
            AppLocalization.string("error.empty_name")
        case .nonPositiveTarget, .nonPositiveMovement:
            AppLocalization.string("error.amount_must_be_positive")
        case .currencyMismatch:
            AppLocalization.string("error.balance_currency_mismatch")
        case .withdrawalExceedsBalance:
            AppLocalization.string("goal.error.withdrawal_exceeds_balance")
        case let .unsupportedPrecision(currency):
            String(
                format: AppLocalization.string("error.currency_precision"),
                currency.value,
                currency.minorUnits
            )
        case .calculationFailed:
            AppLocalization.string("error.calculation_unavailable")
        case .targetBeforeCreation, .movementBeforeCreation,
             .resetBeforeCreation, .duplicateMovementID, .duplicateResetID,
             .invalidOriginContext, .invalidDate:
            AppLocalization.string("goal.error.invalid")
        }
    }
}

extension JournalEntryValidationError: @retroactive LocalizedError {
    public var errorDescription: String? {
        AppLocalization.string("error.balance_invalid")
    }
}

extension BudgetTreeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        AppLocalization.string("error.budget_invalid")
    }
}

extension DecimalCalculationError: @retroactive LocalizedError {
    public var errorDescription: String? {
        AppLocalization.string("error.balance_invalid")
    }
}

extension CurrencyCodeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        AppLocalization.string("error.currency_invalid")
    }
}

extension MoneyError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notANumber:
            AppLocalization.string("error.invalid_amount")
        case .currencyMismatch:
            AppLocalization.string("error.balance_currency_mismatch")
        case let .unsupportedPrecision(currency):
            String(
                format: AppLocalization.string("error.currency_precision"),
                currency.value,
                currency.minorUnits
            )
        case .exceedsNewWriteMaximum:
            AppLocalization.string("error.amount_too_large")
        }
    }
}
