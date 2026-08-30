import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func fetch(collection: String, recordID: String) throws -> Data? {
        try withStatement(
            "SELECT payload FROM records WHERE collection = ? AND record_id = ?;"
        ) { statement in
            try bindText(collection, at: 1, to: statement)
            try bindText(recordID, at: 2, to: statement)

            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return data(from: statement, column: 0)
        }
    }

    func fetchAll(collection: String) throws -> [(id: String, payload: Data)] {
        try withStatement(
            """
            SELECT record_id, payload
            FROM records
            WHERE collection = ?
            ORDER BY record_id ASC;
            """
        ) { statement in
            try bindText(collection, at: 1, to: statement)
            var records: [StoredPayload] = []

            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw makeError(code: result) }
                guard let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: SQLITE_CORRUPT)
                }
                records.append(
                    StoredPayload(
                        id: String(cString: rawID),
                        payload: data(from: statement, column: 1)
                    )
                )
            }

            return records.map { ($0.id, $0.payload) }
        }
    }

    func fetch(
        collection: String,
        recordIDs: [String]
    ) throws -> [(id: String, payload: Data)] {
        guard !recordIDs.isEmpty else { return [] }
        let sortedIDs = Array(Set(recordIDs)).sorted()
        var records: [StoredPayload] = []
        // One collection bind plus 400 record IDs remains comfortably below
        // SQLite's default host-parameter limit.
        for start in stride(from: 0, to: sortedIDs.count, by: 400) {
            try Task.checkCancellation()
            let batch = Array(sortedIDs[start..<min(start + 400, sortedIDs.count)])
            let fetched: [StoredPayload] = try withStatement(
                """
                SELECT record_id, payload
                FROM records
                WHERE collection = ?
                  AND record_id IN (\(Self.placeholders(batch.count)))
                ORDER BY record_id ASC;
                """
            ) { statement in
                try bindText(collection, at: 1, to: statement)
                for (offset, recordID) in batch.enumerated() {
                    try bindText(recordID, at: Int32(offset + 2), to: statement)
                }
                var batchRecords: [StoredPayload] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW,
                          let rawID = sqlite3_column_text(statement, 0) else {
                        throw makeError(
                            code: result == SQLITE_ROW ? SQLITE_CORRUPT : result
                        )
                    }
                    batchRecords.append(StoredPayload(
                        id: String(cString: rawID),
                        payload: data(from: statement, column: 1)
                    ))
                }
                return batchRecords
            }
            records.append(contentsOf: fetched)
        }
        return records.map { ($0.id, $0.payload) }
    }

    func fetchJournalEntryPage(
        startDate: Date?,
        endDateExclusive: Date?,
        startDayKey: Int?,
        endDayKeyExclusive: Int?,
        after cursor: JournalEntryPageCursor?,
        limit: Int
    ) throws -> IndexedPayloadPage {
        try Task.checkCancellation()
        var predicates = [
            "records.collection = ?",
            "records.indexed_at IS NOT NULL"
        ]
        if startDate != nil { predicates.append("records.indexed_at >= ?") }
        if endDateExclusive != nil { predicates.append("records.indexed_at < ?") }
        if startDayKey != nil {
            predicates.append("journal_entry_index.origin_day_key >= ?")
        }
        if endDayKeyExclusive != nil {
            predicates.append("journal_entry_index.origin_day_key < ?")
        }
        if cursor != nil {
            predicates.append(
                "(records.indexed_at < ? OR "
                    + "(records.indexed_at = ? AND records.record_id < ?))"
            )
        }
        let sql = """
        SELECT records.record_id, records.payload, records.indexed_at
        FROM records
        JOIN journal_entry_index
            ON journal_entry_index.entry_id = records.record_id
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY records.indexed_at DESC, records.record_id DESC
        LIMIT ?;
        """

        return try withStatement(sql) { statement in
            var binding: Int32 = 1
            try bindText(
                RecordCollection.journalEntries.rawValue,
                at: binding,
                to: statement
            )
            binding += 1
            if let startDate {
                try bindDouble(
                    startDate.timeIntervalSince1970,
                    at: binding,
                    to: statement
                )
                binding += 1
            }
            if let endDateExclusive {
                try bindDouble(
                    endDateExclusive.timeIntervalSince1970,
                    at: binding,
                    to: statement
                )
                binding += 1
            }
            if let startDayKey {
                guard sqlite3_bind_int64(
                    statement,
                    binding,
                    Int64(startDayKey)
                ) == SQLITE_OK else { throw makeError() }
                binding += 1
            }
            if let endDayKeyExclusive {
                guard sqlite3_bind_int64(
                    statement,
                    binding,
                    Int64(endDayKeyExclusive)
                ) == SQLITE_OK else { throw makeError() }
                binding += 1
            }
            if let cursor {
                let timestamp = cursor.occurredAt.timeIntervalSince1970
                try bindDouble(timestamp, at: binding, to: statement)
                binding += 1
                try bindDouble(timestamp, at: binding, to: statement)
                binding += 1
                try bindText(cursor.recordID, at: binding, to: statement)
                binding += 1
            }
            guard sqlite3_bind_int64(
                statement,
                binding,
                Int64(limit + 1)
            ) == SQLITE_OK else {
                throw makeError()
            }

            var rows: [IndexedPayloadRecord] = []
            while true {
                if rows.count.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                rows.append(
                    IndexedPayloadRecord(
                        id: String(cString: rawID),
                        payload: data(from: statement, column: 1),
                        indexedAt: sqlite3_column_double(statement, 2)
                    )
                )
            }
            try Task.checkCancellation()

            let hasMore = rows.count > limit
            let visibleRows = hasMore ? Array(rows.prefix(limit)) : rows
            let nextCursor = hasMore ? visibleRows.last.map {
                JournalEntryPageCursor(
                    occurredAt: Date(timeIntervalSince1970: $0.indexedAt),
                    recordID: $0.id
                )
            } : nil
            return IndexedPayloadPage(
                records: visibleRows,
                nextCursor: nextCursor
            )
        }
    }

    func fetchJournalPostings(
        startDate: Date,
        endDateExclusive: Date
    ) throws -> [IndexedPostingRow] {
        try withStatement(
            """
            SELECT posting.entry_id, posting.occurred_at, entry.origin_day_key,
                posting.posting_id, posting.account_id, posting.currency,
                posting.amount_text
            FROM journal_posting_index AS posting
            JOIN journal_entry_index AS entry ON entry.entry_id = posting.entry_id
            WHERE posting.occurred_at >= ? AND posting.occurred_at < ?
            ORDER BY posting.occurred_at DESC, posting.entry_id DESC,
                posting.posting_id ASC;
            """
        ) { statement in
            try bindDouble(startDate.timeIntervalSince1970, at: 1, to: statement)
            try bindDouble(endDateExclusive.timeIntervalSince1970, at: 2, to: statement)
            return try readPostingRows(from: statement)
        }
    }

    func fetchJournalPostings(
        startDayKey: Int,
        endDayKeyExclusive: Int
    ) throws -> [IndexedPostingRow] {
        try withStatement(
            """
            SELECT posting.entry_id, posting.occurred_at, entry.origin_day_key,
                posting.posting_id, posting.account_id, posting.currency,
                posting.amount_text
            FROM journal_entry_index AS entry
            JOIN journal_posting_index AS posting ON posting.entry_id = entry.entry_id
            WHERE entry.origin_day_key >= ? AND entry.origin_day_key < ?
            ORDER BY posting.occurred_at DESC, posting.entry_id DESC,
                posting.posting_id ASC;
            """
        ) { statement in
            guard sqlite3_bind_int64(
                statement,
                1,
                Int64(startDayKey)
            ) == SQLITE_OK,
            sqlite3_bind_int64(
                statement,
                2,
                Int64(endDayKeyExclusive)
            ) == SQLITE_OK else { throw makeError() }
            return try readPostingRows(from: statement)
        }
    }

    func fetchBudgetPostings(
        startDayKey: Int,
        endDayKeyExclusive: Int
    ) throws -> [IndexedPostingRow] {
        try withStatement(
            """
            SELECT attribution.entry_id,
                   attribution.occurred_at,
                   attribution.origin_day_key,
                   posting.posting_id,
                   posting.account_id,
                   posting.currency,
                   posting.amount_text
            FROM budget_attribution_entry_index AS attribution
            JOIN budget_attribution_posting_index AS posting
                ON posting.entry_id = attribution.entry_id
            WHERE attribution.origin_day_key >= ?
                AND attribution.origin_day_key < ?

            UNION ALL

            SELECT journal.entry_id,
                   posting.occurred_at,
                   journal.origin_day_key,
                   posting.posting_id,
                   posting.account_id,
                   posting.currency,
                   posting.amount_text
            FROM journal_entry_index AS journal
            JOIN journal_posting_index AS posting
                ON posting.entry_id = journal.entry_id
            WHERE journal.origin_day_key >= ?
                AND journal.origin_day_key < ?
                AND NOT EXISTS (
                    SELECT 1
                    FROM budget_attribution_entry_index AS attribution
                    WHERE attribution.entry_id = journal.entry_id
                )
            ORDER BY 2 DESC, 1 DESC, 4 ASC;
            """
        ) { statement in
            for binding in [Int32(1), Int32(3)] {
                guard sqlite3_bind_int64(
                    statement,
                    binding,
                    Int64(startDayKey)
                ) == SQLITE_OK,
                sqlite3_bind_int64(
                    statement,
                    binding + 1,
                    Int64(endDayKeyExclusive)
                ) == SQLITE_OK else { throw makeError() }
            }
            return try readPostingRows(from: statement)
        }
    }
}
