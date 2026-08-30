import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func replaceJournalIndex(
        entryID: String,
        with index: JournalIndexWrite?,
        observesCancellation: Bool = true
    ) throws {
        try deleteJournalIndex(entryID: entryID)
        guard let index else { return }
        try withStatement(
            """
            INSERT INTO journal_entry_index (
                entry_id, occurred_at, origin_day_key, source_fingerprint,
                budget_integrity_fingerprint
            ) VALUES (?, ?, ?, ?, ?);
            """
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try bindDouble(index.occurredAt, at: 2, to: statement)
            guard sqlite3_bind_int64(
                statement,
                3,
                Int64(index.originDayKey)
            ) == SQLITE_OK else { throw makeError() }
            try bindOptionalText(index.sourceFingerprint, at: 4, to: statement)
            try bindBlob(
                index.budgetIntegrityFingerprint,
                at: 5,
                to: statement
            )
            try stepExpectingDone(statement)
        }
        for (postingIndex, posting) in index.postings.enumerated() {
            if observesCancellation && postingIndex.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            try withStatement(
                """
                INSERT INTO journal_posting_index (
                    entry_id, posting_id, occurred_at, account_id,
                    currency, amount_text
                ) VALUES (?, ?, ?, ?, ?, ?);
                """
            ) { statement in
                try bindText(entryID, at: 1, to: statement)
                try bindText(posting.postingID, at: 2, to: statement)
                try bindDouble(index.occurredAt, at: 3, to: statement)
                try bindText(posting.accountID, at: 4, to: statement)
                try bindText(posting.currency, at: 5, to: statement)
                try bindText(posting.amount, at: 6, to: statement)
                try stepExpectingDone(statement)
            }
        }
    }

    func deleteJournalIndex(entryID: String) throws {
        try withStatement(
            "DELETE FROM journal_entry_index WHERE entry_id = ?;"
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
    }

    func postingTotals(
        forEntryID entryID: String
    ) throws -> (totals: [BalanceKey: Decimal], rowCount: Int) {
        try withStatement(
            """
            SELECT account_id, currency, amount_text
            FROM journal_posting_index
            WHERE entry_id = ?;
            """
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            var result: [BalanceKey: Decimal] = [:]
            var rowCount = 0
            let locale = Locale(identifier: "en_US_POSIX")
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0),
                      let rawCurrency = sqlite3_column_text(statement, 1),
                      let rawAmount = sqlite3_column_text(statement, 2),
                      let amount = Decimal(
                        string: String(cString: rawAmount),
                        locale: locale
                      ) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                let key = BalanceKey(
                    accountID: String(cString: rawAccountID),
                    currency: String(cString: rawCurrency)
                )
                result[key] = try CheckedDecimal.adding(
                    result[key] ?? .zero,
                    amount
                )
                rowCount += 1
            }
            return (result, rowCount)
        }
    }

    func postingTotals(
        for index: JournalIndexWrite?
    ) throws -> [BalanceKey: Decimal] {
        guard let index else { return [:] }
        let locale = Locale(identifier: "en_US_POSIX")
        var result: [BalanceKey: Decimal] = [:]
        for posting in index.postings {
            guard let amount = Decimal(string: posting.amount, locale: locale) else {
                throw makeError(code: SQLITE_CORRUPT)
            }
            let key = BalanceKey(
                accountID: posting.accountID,
                currency: posting.currency
            )
            result[key] = try CheckedDecimal.adding(
                result[key] ?? .zero,
                amount
            )
        }
        return result
    }

    /// Applies exact posting deltas by reading one compact row per affected
    /// account/currency. This is O(changed postings), never O(journal size).
    func applyBalanceDeltas(
        _ deltas: [BalanceKey: Decimal]
    ) throws -> Int {
        let locale = Locale(identifier: "en_US_POSIX")
        var rowsRead = 0
        for (key, delta) in deltas where delta != .zero {
            let existing: Decimal? = try withStatement(
                """
                SELECT amount_text FROM journal_balance
                WHERE account_id = ? AND currency = ?;
                """
            ) { statement in
                try bindText(key.accountID, at: 1, to: statement)
                try bindText(key.currency, at: 2, to: statement)
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return nil }
                guard step == SQLITE_ROW,
                      let rawAmount = sqlite3_column_text(statement, 0),
                      let value = Decimal(
                        string: String(cString: rawAmount),
                        locale: locale
                      ) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                rowsRead += 1
                return value
            }
            let updated = try CheckedDecimal.adding(existing ?? .zero, delta)
            if updated == .zero {
                try withStatement(
                    """
                    DELETE FROM journal_balance
                    WHERE account_id = ? AND currency = ?;
                    """
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try stepExpectingDone(statement)
                }
            } else {
                try withStatement(
                    """
                    INSERT INTO journal_balance (account_id, currency, amount_text)
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_id, currency) DO UPDATE SET
                        amount_text = excluded.amount_text;
                    """
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try bindText(
                        NSDecimalNumber(decimal: updated).stringValue,
                        at: 3,
                        to: statement
                    )
                    try stepExpectingDone(statement)
                }
            }
        }
        return rowsRead
    }

    func rebuildBalances(
        for keys: Set<BalanceKey>,
        observesCancellation: Bool = true
    ) throws {
        guard !keys.isEmpty else { return }
        let locale = Locale(identifier: "en_US_POSIX")
        var totals: [BalanceKey: Decimal] = [:]
        var rowIndex = 0
        try withStatement(
            """
            SELECT account_id, currency, amount_text
            FROM journal_posting_index;
            """
        ) { statement in
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0),
                      let rawCurrency = sqlite3_column_text(statement, 1),
                      let rawAmount = sqlite3_column_text(statement, 2) else {
                    throw makeError(
                        code: step == SQLITE_ROW ? SQLITE_CORRUPT : step
                    )
                }
                if observesCancellation && rowIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                rowIndex += 1
                let key = BalanceKey(
                    accountID: String(cString: rawAccountID),
                    currency: String(cString: rawCurrency)
                )
                guard keys.contains(key) else { continue }
                guard let amount = Decimal(
                    string: String(cString: rawAmount),
                    locale: locale
                ) else {
                    throw makeError(code: SQLITE_CORRUPT)
                }
                totals[key] = try CheckedDecimal.adding(
                    totals[key] ?? .zero,
                    amount
                )
            }
        }

        for (keyIndex, key) in keys.enumerated() {
            if observesCancellation && keyIndex.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if let total = totals[key] {
                try withStatement(
                    """
                    INSERT INTO journal_balance (account_id, currency, amount_text)
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_id, currency) DO UPDATE SET
                        amount_text = excluded.amount_text;
                    """
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try bindText(
                        NSDecimalNumber(decimal: total).stringValue,
                        at: 3,
                        to: statement
                    )
                    try stepExpectingDone(statement)
                }
            } else {
                try withStatement(
                    "DELETE FROM journal_balance WHERE account_id = ? AND currency = ?;"
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try stepExpectingDone(statement)
                }
            }
        }
    }
}
