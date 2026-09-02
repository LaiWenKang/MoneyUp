import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func verifyCipher() throws {
        try execute("SELECT count(*) FROM sqlite_master;")

        let version: String? = try withStatement("PRAGMA cipher_version;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let rawVersion = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return String(cString: rawVersion)
        }

        guard let version, !version.isEmpty else {
            throw PersistenceError.cipherUnavailable
        }
    }

    func configure() throws {
        try execute("PRAGMA cipher_memory_security = ON;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA temp_store = MEMORY;")
        guard try usesMemoryOnlyTemporaryStorage() else {
            throw PersistenceError.databaseFailure(
                code: SQLITE_MISUSE,
                message: "SQLCipher refused memory-only temporary storage"
            )
        }
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = FULL;")
        try execute("PRAGMA secure_delete = ON;")
    }

    func usesMemoryOnlyTemporaryStorage() throws -> Bool {
        try withStatement("PRAGMA temp_store;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw makeError()
            }
            // SQLite documents 2 as MEMORY (0 is compile-time default, 1 FILE).
            return sqlite3_column_int(statement, 0) == 2
        }
    }

    func migrateIfNeeded() throws {
        var currentVersion = try storedSchemaVersion()
        guard currentVersion <= supportedSchemaVersion else {
            throw PersistenceError.unsupportedSchema(
                found: currentVersion,
                supported: supportedSchemaVersion
            )
        }
        if currentVersion == 0 {
            try migrateFreshStoreToVersion2()
            currentVersion = 2
        }
        if currentVersion < 2 {
            try migrateLegacyStoreToVersion2()
            currentVersion = 2
        }
        if currentVersion < 3 {
            try migrateToVersion3()
            currentVersion = 3
        }
        if currentVersion < 4 {
            try migrateToVersion4()
            currentVersion = 4
        }
        if currentVersion < 5 {
            try migrateToVersion5()
            currentVersion = 5
        }
        if currentVersion < 6 {
            try migrateToVersion6()
            currentVersion = 6
        }
        if currentVersion < 7 {
            try migrateToVersion7()
            currentVersion = 7
        }
        guard currentVersion < 8 else { return }
        try migrateToVersion8()
    }

    private func storedSchemaVersion() throws -> Int32 {
        try withStatement("PRAGMA user_version;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw makeError()
            }
            return sqlite3_column_int(statement, 0)
        }
    }

    private func performMigration(_ migration: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try migration()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func migrateFreshStoreToVersion2() throws {
        try performMigration {
            try execute(
                """
                CREATE TABLE records (
                    collection TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    payload BLOB NOT NULL CHECK(length(payload) > 0),
                    updated_at REAL NOT NULL,
                    indexed_at REAL,
                    PRIMARY KEY (collection, record_id)
                ) WITHOUT ROWID;
                """
            )
            try execute(
                "CREATE INDEX records_updated_at ON records(collection, updated_at);"
            )
            try execute(
                """
                CREATE INDEX records_chronological
                ON records(collection, indexed_at DESC, record_id DESC);
                """
            )
            try execute("PRAGMA user_version = 2;")
        }
    }

    private func migrateLegacyStoreToVersion2() throws {
        try performMigration {
            try execute("ALTER TABLE records ADD COLUMN indexed_at REAL;")
            try execute(
                """
                CREATE INDEX records_chronological
                ON records(collection, indexed_at DESC, record_id DESC);
                """
            )
            for record in try fetchAll(
                collection: RecordCollection.journalEntries.rawValue
            ) {
                guard let indexedAt = try journalIndexedAt(
                    collection: RecordCollection.journalEntries.rawValue,
                    payload: record.payload
                ) else { continue }
                try updateChronologicalIndex(
                    recordID: record.id,
                    indexedAt: indexedAt
                )
            }
            try execute("PRAGMA user_version = 2;")
        }
    }

    private func updateChronologicalIndex(
        recordID: String,
        indexedAt: TimeInterval
    ) throws {
        try withStatement(
            """
            UPDATE records
            SET indexed_at = ?
            WHERE collection = ? AND record_id = ?;
            """
        ) { statement in
            try bindDouble(indexedAt, at: 1, to: statement)
            try bindText(
                RecordCollection.journalEntries.rawValue,
                at: 2,
                to: statement
            )
            try bindText(recordID, at: 3, to: statement)
            try stepExpectingDone(statement)
        }
    }

    private func migrateToVersion3() throws {
        try performMigration {
            try createJournalIndexTables()
            var affectedBalances = Set<BalanceKey>()
            for record in try fetchAll(
                collection: RecordCollection.journalEntries.rawValue
            ) {
                guard let index = try journalIndexWrite(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: record.id,
                    payload: record.payload
                ) else {
                    try clearJournalChronologicalIndex(recordID: record.id)
                    continue
                }
                try replaceJournalIndex(entryID: record.id, with: index)
                affectedBalances.formUnion(
                    index.postings.map {
                        BalanceKey(accountID: $0.accountID, currency: $0.currency)
                    }
                )
            }
            try rebuildBalances(for: affectedBalances)
            try execute("PRAGMA user_version = 3;")
        }
    }

    private func migrateToVersion4() throws {
        try performMigration {
            try createReceiptAttachmentIndexTable()
            let attachmentRecordIDs = try recordIDs(
                collection: RecordCollection.receiptAttachments.rawValue
            )
            for recordID in attachmentRecordIDs {
                guard let payload = try fetch(
                    collection: RecordCollection.receiptAttachments.rawValue,
                    recordID: recordID
                ) else { continue }
                guard let index = receiptAttachmentIndexWrite(
                    collection: RecordCollection.receiptAttachments.rawValue,
                    recordID: recordID,
                    payload: payload
                ) else { continue }
                try replaceReceiptAttachmentIndex(
                    attachmentID: recordID,
                    with: index
                )
            }
            try execute("PRAGMA user_version = 4;")
        }
    }

    private func migrateToVersion5() throws {
        try performMigration {
            try createStoreMetricsTable()
            try execute("PRAGMA user_version = 5;")
        }
    }

    private func migrateToVersion6() throws {
        try performMigration {
            try addBudgetIntegrityFingerprintIfNeeded()
            try createBudgetAttributionIndexTables()
            try populateBudgetIntegrityFingerprints()
            try populateBudgetAttributionIndexes()
            try execute("PRAGMA user_version = 6;")
        }
    }

    private func migrateToVersion7() throws {
        try performMigration {
            try createIntelligenceIndexTables()
            try rebuildAllIntelligenceIndexesFromRecords()
            try execute("PRAGMA user_version = 7;")
        }
    }

    /// Loan and allowance data use the generic encrypted record table. This
    /// version still marks the compatibility boundary so older builds reject
    /// books that may contain planning records they cannot present.
    private func migrateToVersion8() throws {
        try performMigration {
            try execute("PRAGMA user_version = 8;")
        }
    }

    private func addBudgetIntegrityFingerprintIfNeeded() throws {
        guard try !journalEntryIndexHasBudgetIntegrityFingerprint() else { return }
        try execute(
            """
            ALTER TABLE journal_entry_index
            ADD COLUMN budget_integrity_fingerprint BLOB
            CHECK(
                budget_integrity_fingerprint IS NULL
                OR length(budget_integrity_fingerprint) = 32
            );
            """
        )
    }

    private func populateBudgetIntegrityFingerprints() throws {
        for record in try fetchAll(
            collection: RecordCollection.journalEntries.rawValue
        ) {
            guard let index = try journalIndexWrite(
                collection: RecordCollection.journalEntries.rawValue,
                recordID: record.id,
                payload: record.payload
            ) else { continue }
            try updateJournalBudgetIntegrityFingerprint(
                entryID: record.id,
                fingerprint: index.budgetIntegrityFingerprint
            )
        }
    }

    private func populateBudgetAttributionIndexes() throws {
        for record in try fetchAll(
            collection: RecordCollection.budgetEntryAttributions.rawValue
        ) {
            let index = budgetAttributionIndexWrite(
                collection: RecordCollection.budgetEntryAttributions.rawValue,
                recordID: record.id,
                payload: record.payload
            )
            try replaceBudgetAttributionIndex(entryID: record.id, with: index)
        }
    }

    func journalEntryIndexHasBudgetIntegrityFingerprint() throws
        -> Bool {
        try withStatement("PRAGMA table_info(journal_entry_index);") {
            statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return false }
                guard result == SQLITE_ROW,
                      let rawName = sqlite3_column_text(statement, 1) else {
                    throw makeError(
                        code: result == SQLITE_ROW ? SQLITE_CORRUPT : result
                    )
                }
                if String(cString: rawName)
                    == "budget_integrity_fingerprint" {
                    return true
                }
            }
        }
    }

    func updateJournalBudgetIntegrityFingerprint(
        entryID: String,
        fingerprint: Data
    ) throws {
        try withStatement(
            """
            UPDATE journal_entry_index
            SET budget_integrity_fingerprint = ?
            WHERE entry_id = ?;
            """
        ) { statement in
            try bindBlob(fingerprint, at: 1, to: statement)
            try bindText(entryID, at: 2, to: statement)
            try stepExpectingDone(statement)
        }
    }

    /// Exact O(1) logical-store totals. The triggers share every record write,
    /// deletion, and restore transaction, so a committed book can be checked
    /// against the portable-archive contract without rescanning large blobs.
    func createStoreMetricsTable() throws {
        try execute(
            """
            CREATE TABLE store_metrics (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK(singleton = 1),
                record_count INTEGER NOT NULL CHECK(record_count >= 0),
                payload_byte_count INTEGER NOT NULL CHECK(payload_byte_count >= 0),
                record_id_byte_count INTEGER NOT NULL CHECK(record_id_byte_count >= 0),
                collection_byte_count INTEGER NOT NULL CHECK(collection_byte_count >= 0)
            ) WITHOUT ROWID;
            """
        )
        try execute(
            """
            INSERT INTO store_metrics (
                singleton,
                record_count,
                payload_byte_count,
                record_id_byte_count,
                collection_byte_count
            )
            SELECT 1,
                   COUNT(*),
                   COALESCE(SUM(length(payload)), 0),
                   COALESCE(SUM(length(CAST(record_id AS BLOB))), 0),
                   COALESCE(SUM(length(CAST(collection AS BLOB))), 0)
            FROM records;
            """
        )
        try execute(
            """
            CREATE TRIGGER store_metrics_records_insert
            AFTER INSERT ON records
            BEGIN
                UPDATE store_metrics
                SET record_count = record_count + 1,
                    payload_byte_count = payload_byte_count + length(NEW.payload),
                    record_id_byte_count = record_id_byte_count
                        + length(CAST(NEW.record_id AS BLOB)),
                    collection_byte_count = collection_byte_count
                        + length(CAST(NEW.collection AS BLOB))
                WHERE singleton = 1;
            END;
            """
        )
        try execute(
            """
            CREATE TRIGGER store_metrics_records_update
            AFTER UPDATE ON records
            BEGIN
                UPDATE store_metrics
                SET payload_byte_count = payload_byte_count
                        - length(OLD.payload) + length(NEW.payload),
                    record_id_byte_count = record_id_byte_count
                        - length(CAST(OLD.record_id AS BLOB))
                        + length(CAST(NEW.record_id AS BLOB)),
                    collection_byte_count = collection_byte_count
                        - length(CAST(OLD.collection AS BLOB))
                        + length(CAST(NEW.collection AS BLOB))
                WHERE singleton = 1;
            END;
            """
        )
        try execute(
            """
            CREATE TRIGGER store_metrics_records_delete
            AFTER DELETE ON records
            BEGIN
                UPDATE store_metrics
                SET record_count = record_count - 1,
                    payload_byte_count = payload_byte_count - length(OLD.payload),
                    record_id_byte_count = record_id_byte_count
                        - length(CAST(OLD.record_id AS BLOB)),
                    collection_byte_count = collection_byte_count
                        - length(CAST(OLD.collection AS BLOB))
                WHERE singleton = 1;
            END;
            """
        )
    }
}
