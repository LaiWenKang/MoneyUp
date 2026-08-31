import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func createIntelligenceIndexTables() throws {
        try createIntelligenceControlTable()
        try createLedgerAccountIntelligenceTable()
        try createJournalIntelligenceSourceTable()
        try createPayeeAffinityTable()
    }

    private func createIntelligenceControlTable() throws {
        try execute(
            """
            CREATE TABLE intelligence_control (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK(singleton = 1),
                enabled INTEGER NOT NULL CHECK(enabled IN (0, 1))
            ) WITHOUT ROWID;
            INSERT INTO intelligence_control(singleton, enabled) VALUES (1, 1);
            """
        )
    }

    private func createLedgerAccountIntelligenceTable() throws {
        try execute(
            """
            CREATE TABLE ledger_account_intelligence_index (
                account_id TEXT NOT NULL PRIMARY KEY,
                kind TEXT NOT NULL,
                currency TEXT,
                system_role TEXT,
                is_archived INTEGER NOT NULL CHECK(is_archived IN (0, 1))
            ) WITHOUT ROWID;
            CREATE INDEX ledger_account_intelligence_kind
            ON ledger_account_intelligence_index(kind, is_archived, account_id);
            """
        )
    }

    private func createJournalIntelligenceSourceTable() throws {
        try execute(
            """
            CREATE TABLE journal_intelligence_source_index (
                entry_id TEXT NOT NULL PRIMARY KEY,
                normalized_payee_key TEXT,
                entry_kind TEXT NOT NULL,
                FOREIGN KEY (entry_id) REFERENCES journal_entry_index(entry_id)
                    ON DELETE CASCADE,
                CHECK(
                    normalized_payee_key IS NULL
                    OR length(CAST(normalized_payee_key AS BLOB)) <= 512
                )
            ) WITHOUT ROWID;
            CREATE INDEX journal_intelligence_source_payee
            ON journal_intelligence_source_index(normalized_payee_key, entry_id)
            WHERE normalized_payee_key IS NOT NULL;
            """
        )
    }

    private func createPayeeAffinityTable() throws {
        try execute(
            """
            CREATE TABLE payee_affinity_index (
                normalized_payee_key TEXT NOT NULL,
                category_account_id TEXT NOT NULL,
                currency TEXT NOT NULL,
                occurrence_count INTEGER NOT NULL CHECK(occurrence_count > 0),
                last_occurrence REAL NOT NULL,
                last_occurrence_day INTEGER NOT NULL
                    CHECK(last_occurrence_day BETWEEN 10101 AND 99991231),
                decayed_recency_score INTEGER NOT NULL
                    CHECK(decayed_recency_score >= 0),
                PRIMARY KEY (
                    normalized_payee_key,
                    currency,
                    category_account_id
                )
            ) WITHOUT ROWID;
            CREATE INDEX payee_affinity_lookup
            ON payee_affinity_index(
                normalized_payee_key,
                currency,
                occurrence_count DESC,
                decayed_recency_score DESC,
                last_occurrence DESC,
                category_account_id ASC
            );
            """
        )
    }

    func rebuildAllIntelligenceIndexesFromRecords() throws {
        try clearIntelligenceDerivedTables()
        let enabled = try storedIntelligencePreference()
        try setIntelligenceControl(enabled)
        guard enabled else { return }
        try rebuildAccountIntelligenceIndex()
        try rebuildJournalIntelligenceSourceIndex()
        for key in try indexedPayeeKeys() {
            try rebuildPayeeAffinity(for: key)
        }
    }

    private func storedIntelligencePreference() throws -> Bool {
        guard let payload = try fetch(
            collection: RecordCollection.profile.rawValue,
            recordID: UserProfile.primaryRecordID
        ) else { return true }
        return (try? JSONDecoder().decode(UserProfile.self, from: payload))?
            .intelligenceEnabled ?? true
    }

    private func rebuildAccountIntelligenceIndex() throws {
        for record in try fetchAll(collection: RecordCollection.accounts.rawValue) {
            guard let account = try? JSONDecoder().decode(
                LedgerAccount.self,
                from: record.payload
            ), account.id.uuidString == record.id else { continue }
            try replaceLedgerAccountIntelligenceIndex(
                accountID: record.id,
                with: LedgerAccountIndexWrite(account: account, recordID: record.id)
            )
        }
    }

    private func rebuildJournalIntelligenceSourceIndex() throws {
        for record in try fetchAll(
            collection: RecordCollection.journalEntries.rawValue
        ) {
            guard let entry = try? JSONDecoder().decode(
                JournalEntry.self,
                from: record.payload
            ), entry.id.uuidString == record.id else { continue }
            try replaceJournalIntelligenceSource(
                entryID: record.id,
                with: JournalIndexWrite(entry: entry, recordID: record.id)
            )
        }
    }

    #if DEBUG
    func installSchema6IntelligenceStateForTesting() throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try clearIntelligenceDerivedTables()
            try execute("DROP TABLE payee_affinity_index;")
            try execute("DROP TABLE journal_intelligence_source_index;")
            try execute("DROP TABLE ledger_account_intelligence_index;")
            try execute("DROP TABLE intelligence_control;")
            try execute("PRAGMA user_version = 6;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
    #endif
}
