import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import SQLCipher

extension SQLCipherConnection {
    func intelligenceIndexingEnabled() throws -> Bool {
        try withStatement(
            "SELECT enabled FROM intelligence_control WHERE singleton = 1;"
        ) { statement in
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else { throw makeError(code: step) }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    func setIntelligenceControl(_ enabled: Bool) throws {
        try withStatement(
            """
            INSERT INTO intelligence_control(singleton, enabled) VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET enabled = excluded.enabled;
            """
        ) { statement in
            guard sqlite3_bind_int(statement, 1, enabled ? 1 : 0) == SQLITE_OK else {
                throw makeError()
            }
            try stepExpectingDone(statement)
        }
    }

    func clearIntelligenceDerivedTables() throws {
        try execute("DELETE FROM payee_affinity_index;")
        try execute("DELETE FROM journal_intelligence_source_index;")
        try execute("DELETE FROM ledger_account_intelligence_index;")
    }

    func replaceLedgerAccountIntelligenceIndex(
        accountID: String,
        with index: LedgerAccountIndexWrite
    ) throws {
        try withStatement(
            """
            INSERT INTO ledger_account_intelligence_index (
                account_id, kind, currency, system_role, is_archived
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
                kind = excluded.kind,
                currency = excluded.currency,
                system_role = excluded.system_role,
                is_archived = excluded.is_archived;
            """
        ) { statement in
            try bindText(accountID, at: 1, to: statement)
            try bindText(index.kind, at: 2, to: statement)
            try bindOptionalText(index.currency, at: 3, to: statement)
            try bindOptionalText(index.systemRole, at: 4, to: statement)
            guard sqlite3_bind_int(
                statement,
                5,
                index.isArchived ? 1 : 0
            ) == SQLITE_OK else { throw makeError() }
            try stepExpectingDone(statement)
        }
    }

    func deleteLedgerAccountIntelligenceIndex(accountID: String) throws {
        try withStatement(
            "DELETE FROM ledger_account_intelligence_index WHERE account_id = ?;"
        ) { statement in
            try bindText(accountID, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
    }

    func replaceJournalIntelligenceSource(
        entryID: String,
        with index: JournalIndexWrite
    ) throws {
        try withStatement(
            """
            INSERT INTO journal_intelligence_source_index (
                entry_id, normalized_payee_key, entry_kind
            ) VALUES (?, ?, ?)
            ON CONFLICT(entry_id) DO UPDATE SET
                normalized_payee_key = excluded.normalized_payee_key,
                entry_kind = excluded.entry_kind;
            """
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try bindOptionalText(index.normalizedPayeeKey, at: 2, to: statement)
            try bindText(index.entryKind, at: 3, to: statement)
            try stepExpectingDone(statement)
        }
    }

    func journalIntelligencePayeeKey(entryID: String) throws -> String? {
        try withStatement(
            """
            SELECT normalized_payee_key
            FROM journal_intelligence_source_index
            WHERE entry_id = ?;
            """
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw makeError(code: step) }
            guard let rawValue = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: rawValue)
        }
    }

    func indexedPayeeKeys() throws -> [String] {
        try withStatement(
            """
            SELECT DISTINCT normalized_payee_key
            FROM journal_intelligence_source_index
            WHERE normalized_payee_key IS NOT NULL
            ORDER BY normalized_payee_key ASC;
            """
        ) { statement in
            var keys: [String] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawKey = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                keys.append(String(cString: rawKey))
            }
            return keys
        }
    }

    func rebuildPayeeAffinity(for payeeKey: String) throws {
        try deletePayeeAffinity(for: payeeKey)
        let rows = try payeeAffinitySourceRows(for: payeeKey)
        var aggregates: [AffinityKey: AffinityAggregate] = [:]
        for row in rows {
            let key = AffinityKey(
                categoryAccountID: row.categoryAccountID,
                currency: row.currency
            )
            var aggregate = aggregates[key] ?? AffinityAggregate(
                count: 0,
                lastOccurrence: row.occurredAt,
                lastOccurrenceDay: row.originDayKey,
                decayedScore: 0
            )
            let rank = min(aggregate.count, 12)
            aggregate.decayedScore += Int64(4_096 >> rank)
            aggregate.count += 1
            aggregates[key] = aggregate
        }
        for key in aggregates.keys.sorted() {
            guard let aggregate = aggregates[key] else { continue }
            try insertPayeeAffinity(
                payeeKey: payeeKey,
                key: key,
                aggregate: aggregate
            )
        }
    }

    func payeeAffinityCandidates(
        payeeKey: String,
        currency: String
    ) throws -> [PayeeAffinityCandidate] {
        let candidates: [PayeeAffinityCandidate] = try withStatement(
            """
            SELECT category_account_id, occurrence_count,
                   last_occurrence_day, decayed_recency_score
            FROM payee_affinity_index
            WHERE normalized_payee_key = ? AND currency = ?
            ORDER BY occurrence_count DESC, decayed_recency_score DESC,
                     last_occurrence DESC, category_account_id ASC;
            """
        ) { statement in
            try bindText(payeeKey, at: 1, to: statement)
            try bindText(currency, at: 2, to: statement)
            var candidates: [PayeeAffinityCandidate] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0),
                      let categoryID = UUID(uuidString: String(cString: rawID)),
                      let currencyCode = try? CurrencyCode(currency) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                candidates.append(PayeeAffinityCandidate(
                    categoryID: categoryID,
                    currency: currencyCode,
                    occurrenceCount: Int(sqlite3_column_int64(statement, 1)),
                    lastOccurrenceDay: Int(sqlite3_column_int64(statement, 2)),
                    decayedScoreUnits: sqlite3_column_int64(statement, 3)
                ))
            }
            return candidates
        }
        lastIntelligenceReadDiagnostics = IntelligenceReadDiagnostics(
            affinityRowsRead: candidates.count,
            observationRowsRead: lastIntelligenceReadDiagnostics.observationRowsRead,
            journalPayloadsDecoded: 0
        )
        return candidates
    }

    private func deletePayeeAffinity(for payeeKey: String) throws {
        try withStatement(
            "DELETE FROM payee_affinity_index WHERE normalized_payee_key = ?;"
        ) { statement in
            try bindText(payeeKey, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
    }

    private func payeeAffinitySourceRows(
        for payeeKey: String
    ) throws -> [AffinitySourceRow] {
        try withStatement(Self.payeeAffinitySourceSQL) { statement in
            try bindText(payeeKey, at: 1, to: statement)
            var rows: [AffinitySourceRow] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawCategoryID = sqlite3_column_text(statement, 0),
                      let rawCurrency = sqlite3_column_text(statement, 1) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                rows.append(AffinitySourceRow(
                    categoryAccountID: String(cString: rawCategoryID),
                    currency: String(cString: rawCurrency),
                    occurredAt: sqlite3_column_double(statement, 2),
                    originDayKey: Int(sqlite3_column_int64(statement, 3))
                ))
            }
            return rows
        }
    }

    private func insertPayeeAffinity(
        payeeKey: String,
        key: AffinityKey,
        aggregate: AffinityAggregate
    ) throws {
        try withStatement(
            """
            INSERT INTO payee_affinity_index (
                normalized_payee_key, category_account_id, currency,
                occurrence_count, last_occurrence, last_occurrence_day,
                decayed_recency_score
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        ) { statement in
            try bindText(payeeKey, at: 1, to: statement)
            try bindText(key.categoryAccountID, at: 2, to: statement)
            try bindText(key.currency, at: 3, to: statement)
            guard sqlite3_bind_int64(
                statement,
                4,
                Int64(aggregate.count)
            ) == SQLITE_OK else { throw makeError() }
            try bindDouble(aggregate.lastOccurrence, at: 5, to: statement)
            guard sqlite3_bind_int64(
                statement,
                6,
                Int64(aggregate.lastOccurrenceDay)
            ) == SQLITE_OK else { throw makeError() }
            guard sqlite3_bind_int64(
                statement,
                7,
                aggregate.decayedScore
            ) == SQLITE_OK else { throw makeError() }
            try stepExpectingDone(statement)
        }
    }

    private static let payeeAffinitySourceSQL = """
        SELECT category.account_id, posting.currency,
               entry.occurred_at, entry.origin_day_key
        FROM journal_intelligence_source_index AS source
        JOIN journal_entry_index AS entry ON entry.entry_id = source.entry_id
        JOIN journal_posting_index AS posting ON posting.entry_id = source.entry_id
        JOIN ledger_account_intelligence_index AS category
          ON category.account_id = posting.account_id
         AND category.kind = source.entry_kind
         AND category.system_role IS NULL
         AND category.is_archived = 0
        WHERE source.normalized_payee_key = ?
          AND source.entry_kind IN ('expense', 'income')
          AND NOT EXISTS (
              SELECT 1
              FROM journal_posting_index AS sibling_posting
              JOIN ledger_account_intelligence_index AS sibling_category
                ON sibling_category.account_id = sibling_posting.account_id
               AND sibling_category.kind = source.entry_kind
               AND sibling_category.system_role IS NULL
               AND sibling_category.is_archived = 0
              WHERE sibling_posting.entry_id = source.entry_id
                AND sibling_posting.currency = posting.currency
                AND sibling_posting.account_id <> posting.account_id
          )
        ORDER BY category.account_id ASC, posting.currency ASC,
                 entry.occurred_at DESC, source.entry_id DESC;
        """
}

private struct AffinityKey: Hashable, Comparable {
    let categoryAccountID: String
    let currency: String

    static func < (lhs: AffinityKey, rhs: AffinityKey) -> Bool {
        (lhs.categoryAccountID, lhs.currency)
            < (rhs.categoryAccountID, rhs.currency)
    }
}

private struct AffinitySourceRow {
    let categoryAccountID: String
    let currency: String
    let occurredAt: TimeInterval
    let originDayKey: Int
}

private struct AffinityAggregate {
    var count: Int
    let lastOccurrence: TimeInterval
    let lastOccurrenceDay: Int
    var decayedScore: Int64
}
