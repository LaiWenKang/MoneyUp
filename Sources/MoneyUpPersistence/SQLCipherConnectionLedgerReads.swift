import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func budgetAttributionIndexSnapshot() throws
        -> BudgetAttributionIndexSnapshot {
        let counts = try budgetAttributionIndexCounts()
        let requiresDetailedValidation = try requiresDetailedBudgetAttributionValidation()
        let issueIDs = try budgetAttributionIssueIDs()
        return BudgetAttributionIndexSnapshot(
            recordCount: counts.0,
            indexedEntryCount: counts.1,
            indexedPostingCount: counts.2,
            requiresDetailedValidation: requiresDetailedValidation,
            issues: issueIDs.map {
                RecordDecodeIssue(
                    collection: .budgetEntryAttributions,
                    recordID: $0
                )
            }
        )
    }

    private func budgetAttributionIndexCounts() throws -> (Int, Int, Int) {
        try withStatement(
            """
            SELECT
                (SELECT COUNT(*) FROM records WHERE collection = ?),
                (SELECT COUNT(*) FROM budget_attribution_entry_index),
                (SELECT COUNT(*) FROM budget_attribution_posting_index);
            """
        ) { statement in
            try bindText(
                RecordCollection.budgetEntryAttributions.rawValue,
                at: 1,
                to: statement
            )
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return (
                Int(sqlite3_column_int64(statement, 0)),
                Int(sqlite3_column_int64(statement, 1)),
                Int(sqlite3_column_int64(statement, 2))
            )
        }
    }

    private func requiresDetailedBudgetAttributionValidation() throws -> Bool {
        // A mismatch can be a valid audited lifecycle remap or a legacy
        // inferred-day attribution, but either case requires the slower exact
        // domain validator. Healthy histories avoid decoding attribution JSON.
        return try withStatement(
            """
            SELECT EXISTS (
                SELECT 1
                FROM budget_attribution_entry_index AS attribution
                JOIN journal_entry_index AS journal
                    ON journal.entry_id = attribution.entry_id
                WHERE attribution.integrity_fingerprint IS NULL
                    OR journal.budget_integrity_fingerprint IS NULL
                    OR attribution.integrity_fingerprint
                        <> journal.budget_integrity_fingerprint
                    OR attribution.occurred_at <> journal.occurred_at
                    OR attribution.origin_day_key <> journal.origin_day_key

                UNION ALL

                SELECT 1
                FROM budget_attribution_posting_index AS attribution
                LEFT JOIN journal_posting_index AS journal
                    ON journal.entry_id = attribution.entry_id
                    AND journal.posting_id = attribution.posting_id
                WHERE journal.posting_id IS NULL
                    OR attribution.account_id <> journal.account_id
                    OR attribution.currency <> journal.currency
                    OR attribution.amount_text <> journal.amount_text

                UNION ALL

                SELECT 1
                FROM journal_posting_index AS journal
                JOIN budget_attribution_entry_index AS attribution_entry
                    ON attribution_entry.entry_id = journal.entry_id
                LEFT JOIN budget_attribution_posting_index AS attribution
                    ON attribution.entry_id = journal.entry_id
                    AND attribution.posting_id = journal.posting_id
                WHERE attribution.posting_id IS NULL
                LIMIT 1
            );
            """
        ) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    private func budgetAttributionIssueIDs() throws -> [String] {
        try withStatement(
            """
            SELECT records.record_id
            FROM records
            LEFT JOIN budget_attribution_entry_index AS attribution
                ON attribution.entry_id = records.record_id
            WHERE records.collection = ?
                AND (
                    attribution.entry_id IS NULL
                    OR records.record_id <> UPPER(records.record_id)
                )

            UNION

            SELECT attribution.entry_id
            FROM budget_attribution_entry_index AS attribution
            LEFT JOIN journal_entry_index AS journal
                ON journal.entry_id = attribution.entry_id
            WHERE journal.entry_id IS NULL
            ORDER BY 1 ASC;
            """
        ) { statement in
            try bindText(
                RecordCollection.budgetEntryAttributions.rawValue,
                at: 1,
                to: statement
            )
            var ids: [String] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(
                        code: result == SQLITE_ROW ? SQLITE_CORRUPT : result
                    )
                }
                ids.append(String(cString: rawID))
            }
            return ids
        }
    }

    func fetchInvalidJournalEntryIDs(
        validAccountIDs: Set<String>,
        expectedAccountCurrencies: [String: String]
    ) throws -> Set<String> {
        let sortedAccountIDs = validAccountIDs.sorted()
        let predicate: String
        if sortedAccountIDs.isEmpty {
            predicate = "1 = 1"
        } else {
            predicate = "account_id NOT IN (\(Self.placeholders(sortedAccountIDs.count)))"
        }
        var result = try withStatement(
            """
            SELECT DISTINCT entry_id
            FROM journal_posting_index
            WHERE \(predicate)
            ORDER BY entry_id ASC;
            """
        ) { statement in
            for (offset, accountID) in sortedAccountIDs.enumerated() {
                try bindText(accountID, at: Int32(offset + 1), to: statement)
            }
            var result = Set<String>()
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawEntryID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                result.insert(String(cString: rawEntryID))
            }
            return result
        }

        // Account metadata is encrypted generic-record state and therefore is
        // supplied by the actor-isolated caller. Query mismatches in bounded
        // batches so books with many accounts never exceed SQLite's variable
        // limit. A single mismatched posting quarantines its complete entry.
        let sortedCurrencies = expectedAccountCurrencies.sorted {
            if $0.key == $1.key { return $0.value < $1.value }
            return $0.key < $1.key
        }
        for batchStart in stride(from: 0, to: sortedCurrencies.count, by: 200) {
            let batch = Array(
                sortedCurrencies[batchStart..<min(batchStart + 200, sortedCurrencies.count)]
            )
            guard !batch.isEmpty else { continue }
            let predicate = batch.map { _ in
                "(account_id = ? AND currency <> ?)"
            }.joined(separator: " OR ")
            let mismatches = try withStatement(
                """
                SELECT DISTINCT entry_id
                FROM journal_posting_index
                WHERE \(predicate)
                ORDER BY entry_id ASC;
                """
            ) { statement in
                var binding: Int32 = 1
                for (accountID, currency) in batch {
                    try bindText(accountID, at: binding, to: statement)
                    binding += 1
                    try bindText(currency, at: binding, to: statement)
                    binding += 1
                }
                var mismatches = Set<String>()
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW,
                          let rawEntryID = sqlite3_column_text(statement, 0) else {
                        throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                    }
                    mismatches.insert(String(cString: rawEntryID))
                }
                return mismatches
            }
            result.formUnion(mismatches)
        }
        return result
    }

    func fetchQuarantinedJournalPostings(
        entryIDs: Set<String>
    ) throws -> [IndexedPostingRow] {
        let sortedEntryIDs = entryIDs.sorted()
        var rows: [IndexedPostingRow] = []
        for batchStart in stride(from: 0, to: sortedEntryIDs.count, by: 400) {
            let batch = Array(
                sortedEntryIDs[batchStart..<min(batchStart + 400, sortedEntryIDs.count)]
            )
            guard !batch.isEmpty else { continue }
            let fetched = try withStatement(
                """
                SELECT posting.entry_id, posting.occurred_at, entry.origin_day_key,
                    posting.posting_id, posting.account_id, posting.currency,
                    posting.amount_text
                FROM journal_posting_index AS posting
                JOIN journal_entry_index AS entry ON entry.entry_id = posting.entry_id
                WHERE posting.entry_id IN (\(Self.placeholders(batch.count)))
                ORDER BY posting.entry_id ASC, posting.posting_id ASC;
                """
            ) { statement in
                for (offset, entryID) in batch.enumerated() {
                    try bindText(entryID, at: Int32(offset + 1), to: statement)
                }
                return try readPostingRows(from: statement)
            }
            rows.append(contentsOf: fetched)
        }
        return rows
    }

    func fetchJournalReferenceCounts(
        validAccountIDs: Set<String>
    ) throws -> [IndexedReferenceCountRow] {
        let sortedAccountIDs = validAccountIDs.sorted()
        guard !sortedAccountIDs.isEmpty else { return [] }
        return try withStatement(
            """
            SELECT account_id, COUNT(DISTINCT entry_id)
            FROM journal_posting_index
            WHERE account_id IN (\(Self.placeholders(sortedAccountIDs.count)))
            GROUP BY account_id
            ORDER BY account_id ASC;
            """
        ) { statement in
            var binding: Int32 = 1
            for accountID in sortedAccountIDs {
                try bindText(accountID, at: binding, to: statement)
                binding += 1
            }
            var rows: [IndexedReferenceCountRow] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                rows.append(
                    IndexedReferenceCountRow(
                        accountID: String(cString: rawAccountID),
                        count: Int(sqlite3_column_int64(statement, 1))
                    )
                )
            }
            return rows
        }
    }

    func readPostingRows(
        from statement: OpaquePointer,
        observesCancellation: Bool = false
    ) throws -> [IndexedPostingRow] {
        var rows: [IndexedPostingRow] = []
        var rowOffset = 0
        while true {
            if observesCancellation, rowOffset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let rawEntryID = sqlite3_column_text(statement, 0),
                  let rawPostingID = sqlite3_column_text(statement, 3),
                  let rawAccountID = sqlite3_column_text(statement, 4),
                  let rawCurrency = sqlite3_column_text(statement, 5),
                  let rawAmount = sqlite3_column_text(statement, 6) else {
                throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
            }
            rows.append(
                IndexedPostingRow(
                    entryID: String(cString: rawEntryID),
                    occurredAt: sqlite3_column_double(statement, 1),
                    originDayKey: Int(sqlite3_column_int64(statement, 2)),
                    postingID: String(cString: rawPostingID),
                    accountID: String(cString: rawAccountID),
                    currency: String(cString: rawCurrency),
                    amount: String(cString: rawAmount)
                )
            )
            rowOffset += 1
        }
        return rows
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    func fetchJournalBalances() throws -> [IndexedBalanceRow] {
        try withStatement(
            """
            SELECT account_id, currency, amount_text
            FROM journal_balance
            ORDER BY account_id ASC, currency ASC;
            """
        ) { statement in
            var rows: [IndexedBalanceRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0),
                      let rawCurrency = sqlite3_column_text(statement, 1),
                      let rawAmount = sqlite3_column_text(statement, 2) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                rows.append(
                    IndexedBalanceRow(
                        accountID: String(cString: rawAccountID),
                        currency: String(cString: rawCurrency),
                        amount: String(cString: rawAmount)
                    )
                )
            }
            return rows
        }
    }

    func fetchUnindexedJournalRecordIDs() throws -> [String] {
        try withStatement(
            """
            SELECT records.record_id
            FROM records
            LEFT JOIN journal_entry_index
                ON journal_entry_index.entry_id = records.record_id
            WHERE records.collection = ?
                AND journal_entry_index.entry_id IS NULL
            ORDER BY records.record_id ASC;
            """
        ) { statement in
            try bindText(
                RecordCollection.journalEntries.rawValue,
                at: 1,
                to: statement
            )
            var ids: [String] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                ids.append(String(cString: rawID))
            }
            return ids
        }
    }

    /// Returns legacy indexed UUID keys whose spelling is not the exact
    /// canonical `UUID.uuidString`. If a canonical twin also exists, both
    /// physical rows are quarantined so balances and history cannot expose
    /// two logical versions of one transaction.
    func fetchNoncanonicalJournalEntryIDs() throws -> Set<String> {
        let aliases: Set<String> = try withStatement(
            """
            SELECT entry_id
            FROM journal_entry_index
            WHERE entry_id <> UPPER(entry_id)
            ORDER BY entry_id ASC;
            """
        ) { statement in
            var ids = Set<String>()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                ids.insert(String(cString: rawID))
            }
            return ids
        }
        guard !aliases.isEmpty else { return [] }
        let canonicalCandidates = aliases.compactMap { recordID in
            UUID(uuidString: recordID)?.uuidString
        }
        return aliases.union(
            try fetchExistingJournalEntryIDs(canonicalCandidates)
        )
    }

    func containsJournalEntry(sourceFingerprint: String) throws -> Bool {
        try withStatement(
            """
            SELECT 1
            FROM journal_entry_index
            WHERE source_fingerprint = ?
            LIMIT 1;
            """
        ) { statement in
            try bindText(sourceFingerprint, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return false }
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return true
        }
    }

    func fetchExistingJournalEntryIDs(_ candidateIDs: [String]) throws -> Set<String> {
        guard !candidateIDs.isEmpty else { return [] }
        var existing = Set<String>()
        // Stay comfortably below SQLite's default host-parameter limit.
        for start in stride(from: 0, to: candidateIDs.count, by: 400) {
            let batch = Array(candidateIDs[start..<min(start + 400, candidateIDs.count)])
            let rows: Set<String> = try withStatement(
                """
                SELECT entry_id
                FROM journal_entry_index
                WHERE entry_id IN (\(Self.placeholders(batch.count)));
                """
            ) { statement in
                for (offset, entryID) in batch.enumerated() {
                    try bindText(entryID, at: Int32(offset + 1), to: statement)
                }
                var result = Set<String>()
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW,
                          let rawEntryID = sqlite3_column_text(statement, 0) else {
                        throw makeError(
                            code: step == SQLITE_ROW ? SQLITE_CORRUPT : step
                        )
                    }
                    result.insert(String(cString: rawEntryID))
                }
                return result
            }
            existing.formUnion(rows)
        }
        return existing
    }

    func fetchJournalSourceFingerprints() throws -> Set<String> {
        try withStatement(
            """
            SELECT DISTINCT source_fingerprint
            FROM journal_entry_index
            WHERE source_fingerprint IS NOT NULL
            ORDER BY source_fingerprint ASC;
            """
        ) { statement in
            var values = Set<String>()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawValue = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                values.insert(String(cString: rawValue))
            }
            return values
        }
    }

    func journalIndexDiagnostics() throws -> JournalIndexDiagnostics {
        func scalar(_ sql: String) throws -> Int {
            try withStatement(sql) { statement in
                let result = sqlite3_step(statement)
                guard result == SQLITE_ROW else { throw makeError(code: result) }
                return Int(sqlite3_column_int64(statement, 0))
            }
        }
        return try JournalIndexDiagnostics(
            journalRecordCount: count(
                collection: RecordCollection.journalEntries.rawValue
            ),
            indexedEntryCount: scalar("SELECT COUNT(*) FROM journal_entry_index;"),
            indexedPostingCount: scalar("SELECT COUNT(*) FROM journal_posting_index;")
        )
    }
}
