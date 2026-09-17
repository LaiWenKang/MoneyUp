import Foundation
import MoneyUpCore

/// Immutable inputs let spreadsheet serialization run without reading UI state.
struct LedgerExportSnapshot: Sendable {
    let entries: [JournalEntry]
    let accounts: [LedgerAccount]
    let rates: [DatedExchangeRate]
    let attachments: [ReceiptAttachmentMetadata]

    func csv() -> String {
        LedgerCSVExporter.export(
            entries.sorted { $0.occurredAt < $1.occurredAt },
            accounts: accounts
        )
    }

    func xlsx() -> Data {
        LedgerXLSXExporter.export(
            entries: entries,
            accounts: accounts,
            rates: rates,
            attachmentMetadata: attachments
        )
    }
}
