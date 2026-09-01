import OSLog

/// Closed, payload-free names for MoneyUp's release performance intervals.
///
/// Do not add associated values. Instruments receives only these static names;
/// financial values, user text, identifiers, paths, and error details stay out
/// of the unified log.
public enum MoneyUpPerformanceOperation: String, CaseIterable, Sendable {
    case storeOpen = "StoreOpen"
    case unlock = "Unlock"
    case ledgerLoad = "LedgerLoad"
    case save = "Save"
    case historyPage = "HistoryPage"
    case historyQuery = "HistoryQuery"
    case csvExport = "CSVExport"
    case xlsxExport = "XLSXExport"
    case archiveExport = "ArchiveExport"
    case archiveRestore = "ArchiveRestore"
    case receiptProcessing = "ReceiptProcessing"
    case projection = "Projection"
    case deterministicIntelligence = "DeterministicIntelligence"
    case unlockToFirstUsefulContent = "UnlockToFirstUsefulContent"
    case transactionSaveToPublication = "TransactionSaveToPublication"
    case historyQueryToContent = "HistoryQueryToContent"
    case historyPageToContent = "HistoryPageToContent"
    case calendarDateComputation = "CalendarDateComputation"

    fileprivate var signpostName: StaticString {
        switch self {
        case .storeOpen: "StoreOpen"
        case .unlock: "Unlock"
        case .ledgerLoad: "LedgerLoad"
        case .save: "Save"
        case .historyPage: "HistoryPage"
        case .historyQuery: "HistoryQuery"
        case .csvExport: "CSVExport"
        case .xlsxExport: "XLSXExport"
        case .archiveExport: "ArchiveExport"
        case .archiveRestore: "ArchiveRestore"
        case .receiptProcessing: "ReceiptProcessing"
        case .projection: "Projection"
        case .deterministicIntelligence: "DeterministicIntelligence"
        case .unlockToFirstUsefulContent: "UnlockToFirstUsefulContent"
        case .transactionSaveToPublication: "TransactionSaveToPublication"
        case .historyQueryToContent: "HistoryQueryToContent"
        case .historyPageToContent: "HistoryPageToContent"
        case .calendarDateComputation: "CalendarDateComputation"
        }
    }
}

/// Fixed, non-domain outcomes make journey samples filterable without exposing
/// amounts, identifiers, user text, paths, errors, or any other runtime value.
public enum MoneyUpPerformanceOutcome: CaseIterable, Equatable, Sendable {
    case success
    case failure
    case cancelled
}

/// Opaque interval state prevents call sites from attaching diagnostic or
/// domain payloads while still allowing synchronous and asynchronous work.
public struct MoneyUpPerformanceInterval: Sendable {
    fileprivate let operation: MoneyUpPerformanceOperation
    fileprivate let state: OSSignpostIntervalState
}

public enum MoneyUpPerformanceSignposts {
    private static let signposter = OSSignposter(
        subsystem: "com.laiwenkang.MoneyUp",
        category: "Performance"
    )

    public static func begin(
        _ operation: MoneyUpPerformanceOperation
    ) -> MoneyUpPerformanceInterval? {
        guard signposter.isEnabled else { return nil }
        let signpostID = signposter.makeSignpostID()
        return MoneyUpPerformanceInterval(
            operation: operation,
            state: signposter.beginInterval(
                operation.signpostName,
                id: signpostID
            )
        )
    }

    public static func end(_ interval: MoneyUpPerformanceInterval?) {
        guard let interval else { return }
        signposter.endInterval(interval.operation.signpostName, interval.state)
    }

    public static func end(
        _ interval: MoneyUpPerformanceInterval?,
        outcome: MoneyUpPerformanceOutcome
    ) {
        guard let interval else { return }
        switch outcome {
        case .success:
            signposter.endInterval(
                interval.operation.signpostName,
                interval.state,
                "outcome=success"
            )
        case .failure:
            signposter.endInterval(
                interval.operation.signpostName,
                interval.state,
                "outcome=failure"
            )
        case .cancelled:
            signposter.endInterval(
                interval.operation.signpostName,
                interval.state,
                "outcome=cancelled"
            )
        }
    }
}
