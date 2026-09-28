import Foundation

/// Deterministic, human-readable ledger export for Numbers, Excel, and other
/// spreadsheet tools. One CSV row represents one posting, preserving the
/// balanced accounting representation instead of flattening away transfers.
public enum LedgerCSVExporter {
    public static func export(
        _ entries: [JournalEntry],
        accounts: [LedgerAccount] = []
    ) -> String {
        let performanceInterval = MoneyUpPerformanceSignposts.begin(.csvExport)
        defer { MoneyUpPerformanceSignposts.end(performanceInterval) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let accountsByID = accounts.reduce(into: [UUID: LedgerAccount]()) {
            $0[$1.id] = $1
        }

        var rows = [[
            "entry_id",
            "entry_kind",
            "occurred_at",
            "origin_day",
            "origin_calendar",
            "origin_time_zone",
            "origin_utc_offset_seconds",
            "origin_inferred",
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
                    String(entry.originContext.dayKey),
                    spreadsheetSafeText(entry.originContext.calendarIdentifier),
                    spreadsheetSafeText(entry.originContext.timeZoneIdentifier),
                    String(entry.originContext.utcOffsetSeconds),
                    entry.originContext.wasInferred ? "true" : "false",
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
        // Bytes, not Characters: "\r\n" is one Character, so a Character check
        // for "\n" or "\r" missed text whose only line breaks were CRLF and left
        // it unquoted, splitting the row.
        let requiresQuotes = value.utf8.contains {
            $0 == 0x2c || $0 == 0x22 || $0 == 0x0a || $0 == 0x0d
        }

        guard requiresQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Prevents user-controlled text from being interpreted as a spreadsheet
    /// formula. Quoting a CSV cell alone does not reliably prevent execution.
    private static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@"]

    private static func spreadsheetSafeText(_ value: String) -> String {
        let firstMeaningfulCharacter = value.first { !$0.isWhitespace }

        guard let firstMeaningfulCharacter,
              formulaPrefixes.contains(firstMeaningfulCharacter) else {
            return value
        }

        return "'" + value
    }
}
