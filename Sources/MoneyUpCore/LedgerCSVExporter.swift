import Foundation

/// Deterministic, human-readable ledger export for Numbers, Excel, and other
/// spreadsheet tools. One CSV row represents one posting, preserving the
/// balanced accounting representation instead of flattening away transfers.
public enum LedgerCSVExporter {
    public static func export(
        _ entries: [JournalEntry],
        accounts: [LedgerAccount] = []
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let accountsByID = accounts.reduce(into: [UUID: LedgerAccount]()) {
            $0[$1.id] = $1
        }

        var rows = [[
            "entry_id",
            "entry_kind",
            "occurred_at",
            "created_at",
            "payee",
            "entry_note",
            "posting_id",
            "account_id",
            "account_name",
            "account_kind",
            "account_type",
            "parent_account_id",
            "amount",
            "currency",
            "posting_memo"
        ]]

        for entry in entries {
            for posting in entry.postings {
                let account = accountsByID[posting.accountID]
                rows.append([
                    entry.id.uuidString.lowercased(),
                    entry.kind.rawValue,
                    formatter.string(from: entry.occurredAt),
                    formatter.string(from: entry.createdAt),
                    spreadsheetSafeText(entry.payee ?? ""),
                    spreadsheetSafeText(entry.note ?? ""),
                    posting.id.uuidString.lowercased(),
                    posting.accountID.uuidString.lowercased(),
                    spreadsheetSafeText(account?.name ?? ""),
                    account?.kind.rawValue ?? "",
                    account?.accountType?.rawValue ?? "",
                    account?.parentID?.uuidString.lowercased() ?? "",
                    NSDecimalNumber(decimal: posting.money.amount).stringValue,
                    posting.money.currency.value,
                    spreadsheetSafeText(posting.memo ?? "")
                ])
            }
        }

        // UTF-8 BOM keeps Chinese account, payee, and category names readable
        // when the CSV is opened directly in Excel on Windows.
        return "\u{feff}" + rows
            .map { $0.map(escape).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ value: String) -> String {
        let requiresQuotes = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")

        guard requiresQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Prevents user-controlled text from being interpreted as a spreadsheet
    /// formula. Quoting a CSV cell alone does not reliably prevent execution.
    private static func spreadsheetSafeText(_ value: String) -> String {
        let firstMeaningfulCharacter = value.first { !$0.isWhitespace }
        let formulaPrefixes: Set<Character> = ["=", "+", "-", "@"]

        guard let firstMeaningfulCharacter,
              formulaPrefixes.contains(firstMeaningfulCharacter) else {
            return value
        }

        return "'" + value
    }
}
