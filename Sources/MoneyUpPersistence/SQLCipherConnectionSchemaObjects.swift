import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func recordIDs(collection: String) throws -> [String] {
        try withStatement(
            """
            SELECT record_id
            FROM records
            WHERE collection = ?
            ORDER BY record_id ASC;
            """
        ) { statement in
            try bindText(collection, at: 1, to: statement)
            var recordIDs: [String] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                recordIDs.append(String(cString: rawID))
            }
            return recordIDs
        }
    }

    func createReceiptAttachmentIndexTable() throws {
        try execute(
            """
            CREATE TABLE receipt_attachment_index (
                attachment_id TEXT NOT NULL PRIMARY KEY,
                entry_id TEXT NOT NULL,
                media_type TEXT NOT NULL,
                byte_count INTEGER NOT NULL CHECK(byte_count > 0),
                created_at REAL NOT NULL
            ) WITHOUT ROWID;
            """
        )
        try execute(
            """
            CREATE INDEX receipt_attachment_index_entry
            ON receipt_attachment_index(entry_id, created_at ASC, attachment_id ASC);
            """
        )
    }

    func createBudgetAttributionIndexTables() throws {
        try execute(
            """
            CREATE TABLE budget_attribution_entry_index (
                entry_id TEXT NOT NULL PRIMARY KEY,
                occurred_at REAL NOT NULL,
                origin_day_key INTEGER NOT NULL
                    CHECK(origin_day_key BETWEEN 10101 AND 99991231),
                integrity_fingerprint BLOB NOT NULL
                    CHECK(length(integrity_fingerprint) = 32)
            ) WITHOUT ROWID;
            """
        )
        try execute(
            """
            CREATE INDEX budget_attribution_entry_day
            ON budget_attribution_entry_index(origin_day_key, entry_id);
            """
        )
        try execute(
            """
            CREATE TABLE budget_attribution_posting_index (
                entry_id TEXT NOT NULL,
                posting_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
                currency TEXT NOT NULL,
                amount_text TEXT NOT NULL CHECK(length(amount_text) > 0),
                PRIMARY KEY (entry_id, posting_id),
                FOREIGN KEY (entry_id)
                    REFERENCES budget_attribution_entry_index(entry_id)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;
            """
        )
        try execute(
            """
            CREATE INDEX budget_attribution_posting_account
            ON budget_attribution_posting_index(account_id, entry_id);
            """
        )
    }

    func createJournalIndexTables() throws {
        try execute(
            """
            CREATE TABLE journal_entry_index (
                entry_id TEXT NOT NULL PRIMARY KEY,
                occurred_at REAL NOT NULL,
                origin_day_key INTEGER NOT NULL,
                source_fingerprint TEXT,
                budget_integrity_fingerprint BLOB
                    CHECK(
                        budget_integrity_fingerprint IS NULL
                        OR length(budget_integrity_fingerprint) = 32
                    )
            ) WITHOUT ROWID;
            """
        )
        try execute(
            """
            CREATE INDEX journal_entry_index_chronological
            ON journal_entry_index(occurred_at DESC, entry_id DESC);
            """
        )
        try execute(
            """
            CREATE INDEX journal_entry_index_origin_day
            ON journal_entry_index(origin_day_key, occurred_at DESC, entry_id DESC);
            """
        )
        try execute(
            """
            CREATE INDEX journal_entry_index_source
            ON journal_entry_index(source_fingerprint)
            WHERE source_fingerprint IS NOT NULL;
            """
        )
        try execute(
            """
            CREATE TABLE journal_posting_index (
                entry_id TEXT NOT NULL,
                posting_id TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                account_id TEXT NOT NULL,
                currency TEXT NOT NULL,
                amount_text TEXT NOT NULL CHECK(length(amount_text) > 0),
                PRIMARY KEY (entry_id, posting_id),
                FOREIGN KEY (entry_id) REFERENCES journal_entry_index(entry_id)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;
            """
        )
        try execute(
            """
            CREATE INDEX journal_posting_index_chronological
            ON journal_posting_index(occurred_at DESC, entry_id DESC);
            """
        )
        try execute(
            """
            CREATE INDEX journal_posting_index_account
            ON journal_posting_index(account_id, entry_id);
            """
        )
        try execute(
            """
            CREATE TABLE journal_balance (
                account_id TEXT NOT NULL,
                currency TEXT NOT NULL,
                amount_text TEXT NOT NULL CHECK(length(amount_text) > 0),
                PRIMARY KEY (account_id, currency)
            ) WITHOUT ROWID;
            """
        )
    }

    func journalIndexedAt(
        collection: String,
        payload: Data
    ) throws -> TimeInterval? {
        guard collection == RecordCollection.journalEntries.rawValue else {
            return nil
        }
        do {
            let entry = try JSONDecoder().decode(
                JournalEntry.self,
                from: payload
            )
            return entry.occurredAt.timeIntervalSince1970
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    func journalIndexWrite(
        collection: String,
        recordID: String,
        payload: Data
    ) throws -> JournalIndexWrite? {
        guard collection == RecordCollection.journalEntries.rawValue else {
            return nil
        }
        do {
            let entry = try JSONDecoder().decode(
                JournalEntry.self,
                from: payload
            )
            guard entry.id.uuidString == recordID else {
                return nil
            }
            return JournalIndexWrite(entry: entry, recordID: recordID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    func receiptAttachmentIndexWrite(
        collection: String,
        recordID: String,
        payload: Data
    ) -> ReceiptAttachmentIndexWrite? {
        guard collection == RecordCollection.receiptAttachments.rawValue,
              let attachment = try? JSONDecoder().decode(
                ReceiptAttachment.self,
                from: payload
              ),
              attachment.id.uuidString == recordID
        else { return nil }
        return ReceiptAttachmentIndexWrite(
            attachment: attachment,
            recordID: recordID
        )
    }

    func budgetAttributionIndexWrite(
        collection: String,
        recordID: String,
        payload: Data
    ) -> BudgetAttributionIndexWrite? {
        guard collection == RecordCollection.budgetEntryAttributions.rawValue,
              let attribution = try? JSONDecoder().decode(
                BudgetEntryAttribution.self,
                from: payload
              ),
              attribution.id.uuidString == recordID else { return nil }
        return try? BudgetAttributionIndexWrite(
            attribution: attribution,
            recordID: recordID
        )
    }

    func clearJournalChronologicalIndex(recordID: String) throws {
        try withStatement(
            """
            UPDATE records SET indexed_at = NULL
            WHERE collection = ? AND record_id = ?;
            """
        ) { statement in
            try bindText(RecordCollection.journalEntries.rawValue, at: 1, to: statement)
            try bindText(recordID, at: 2, to: statement)
            try stepExpectingDone(statement)
        }
    }

    func execute(_ sql: String) throws {
        try requireOpen()
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw makeError(code: result)
        }
    }

    func withStatement<Result>(
        _ sql: String,
        operation: (OpaquePointer) throws -> Result
    ) throws -> Result {
        try requireOpen()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw makeError(code: result)
        }
        defer { sqlite3_finalize(statement) }
        return try operation(statement)
    }

    func bindText(
        _ value: String,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else { throw makeError(code: result) }
    }

    func bindOptionalText(
        _ value: String?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        if let value {
            try bindText(value, at: index, to: statement)
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw makeError()
            }
        }
    }

    func bindBlob(
        _ value: Data,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                sqliteTransient
            )
        }
        guard result == SQLITE_OK else { throw makeError(code: result) }
    }

    func bindDouble(
        _ value: Double,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        guard value.isFinite,
              sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw makeError()
        }
    }

    func bindOptionalDouble(
        _ value: Double?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        if let value {
            try bindDouble(value, at: index, to: statement)
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw makeError()
            }
        }
    }

    func data(from statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    func stepExpectingDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw makeError(code: result) }
    }

    func requireOpen() throws {
        guard database != nil else { throw PersistenceError.databaseClosed }
    }

    func makeError(code: Int32? = nil) -> PersistenceError {
        let resolvedCode = code ?? sqlite3_extended_errcode(database)
        let message: String
        if let database, let rawMessage = sqlite3_errmsg(database) {
            message = String(cString: rawMessage)
        } else {
            message = "SQLCipher database error"
        }
        return .databaseFailure(code: resolvedCode, message: message)
    }

    var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
