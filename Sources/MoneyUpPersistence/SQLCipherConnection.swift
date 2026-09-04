import Foundation
import MoneyUpCore
import SQLCipher

final class SQLCipherConnection: @unchecked Sendable {
    struct StoredPayload {
        let id: String
        let payload: Data
    }

    struct BalanceKey: Hashable {
        let accountID: String
        let currency: String
    }

    private struct WriteTransactionState {
        var balanceDeltas: [BalanceKey: Decimal] = [:]
        var priorPostingRowsRead = 0
        var journalEntriesChanged = 0
        var affectedPayeeKeys = Set<String>()
        var accountIntelligenceChanged = false
        var intelligencePreference: Bool?
    }

    var database: OpaquePointer?
    #if DEBUG
    var shouldFailNextRestoreRollbackForTesting = false
    var shouldFailNextWriteRollbackForTesting = false
    #endif
    let supportedSchemaVersion: Int32
    var lastJournalWriteDiagnostics = JournalWriteDiagnostics(
        priorPostingRowsRead: 0,
        compactBalanceRowsRead: 0,
        journalEntriesChanged: 0
    )
    var lastJournalLedgerReadDiagnostics = JournalLedgerReadDiagnostics(
        invalidEntryIDsRead: 0,
        quarantinedPostingRowsRead: 0,
        referenceAggregateRowsRead: 0
    )
    var lastReceiptAttachmentReadDiagnostics =
        ReceiptAttachmentReadDiagnostics(metadataRowsRead: 0, blobPayloadsDecoded: 0)
    var receiptAttachmentSearchCache:
        (query: String, matches: [ReceiptAttachmentSearchMatch])?
    var lastIntelligenceReadDiagnostics = IntelligenceReadDiagnostics(
        affinityRowsRead: 0,
        observationRowsRead: 0,
        journalPayloadsDecoded: 0
    )

    init(
        databaseURL: URL,
        key: Data,
        supportedSchemaVersion: Int32
    ) throws {
        self.supportedSchemaVersion = supportedSchemaVersion

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard openResult == SQLITE_OK else {
            let error = makeError(code: openResult)
            close()
            throw error
        }

        sqlite3_extended_result_codes(database, 1)

        let keyResult = key.withUnsafeBytes { buffer in
            sqlite3_key(database, buffer.baseAddress, Int32(buffer.count))
        }
        guard keyResult == SQLITE_OK else {
            let error = makeError(code: keyResult)
            close()
            throw error
        }

        do {
            try verifyCipher()
            try configure()
            try migrateIfNeeded()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    func upsertRecord(
        collection: String,
        recordID: String,
        payload: Data,
        updatedAt: TimeInterval,
        indexedAt: TimeInterval?
    ) throws {
        try withStatement(
            """
            INSERT INTO records (collection, record_id, payload, updated_at, indexed_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(collection, record_id) DO UPDATE SET
                payload = excluded.payload,
                updated_at = excluded.updated_at,
                indexed_at = excluded.indexed_at;
            """
        ) { statement in
            try bindText(collection, at: 1, to: statement)
            try bindText(recordID, at: 2, to: statement)
            try bindBlob(payload, at: 3, to: statement)
            guard sqlite3_bind_double(statement, 4, updatedAt) == SQLITE_OK else {
                throw makeError()
            }
            try bindOptionalDouble(indexedAt, at: 5, to: statement)
            try stepExpectingDone(statement)
        }
    }

    func write(
        _ records: [RecordWrite],
        removing deletions: [RecordDeletion],
        relinkingReceiptAttachments relink: ReceiptAttachmentRelink? = nil
    ) throws {
        guard !records.isEmpty || !deletions.isEmpty || relink != nil else { return }
        try validateWriteIndexes(records)
        try execute("BEGIN IMMEDIATE;")
        do {
            let diagnostics = try performWriteTransaction(
                records,
                removing: deletions,
                relinkingReceiptAttachments: relink
            )
            try execute("COMMIT;")
            lastJournalWriteDiagnostics = diagnostics
        } catch let operationError {
            try rollbackFailedWrite()
            throw operationError
        }
    }

    private func validateWriteIndexes(_ records: [RecordWrite]) throws {
        for record in records where record.collection == .journalEntries {
            guard record.journalIndex != nil, record.indexedAt != nil else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .journalEntries,
                    recordID: record.id
                )
            }
        }
        for record in records where record.collection == .receiptAttachments {
            guard record.receiptAttachmentIndex != nil else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: record.id
                )
            }
        }
        for record in records where record.collection == .budgetEntryAttributions {
            guard record.budgetAttributionIndex != nil else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .budgetEntryAttributions,
                    recordID: record.id
                )
            }
        }
    }

    private func performWriteTransaction(
        _ records: [RecordWrite],
        removing deletions: [RecordDeletion],
        relinkingReceiptAttachments relink: ReceiptAttachmentRelink?
    ) throws -> JournalWriteDiagnostics {
        let metricsBeforeWrite = try storageMetrics()
        let updatedAt = Date().timeIntervalSince1970
        var state = WriteTransactionState()
        for record in records {
            try apply(record, updatedAt: updatedAt, state: &state)
        }
        if let relink {
            try relinkReceiptAttachments(
                from: relink.sourceEntryID,
                to: relink.destinationEntryID,
                updatedAt: updatedAt
            )
        }
        for deletion in deletions {
            try apply(deletion, state: &state)
        }
        let compactBalanceRowsRead = try applyBalanceDeltas(state.balanceDeltas)
        try finalizeIntelligenceWrite(state)
        try enforceLogicalStoreLimits(
            before: metricsBeforeWrite,
            after: storageMetrics()
        )
        return JournalWriteDiagnostics(
            priorPostingRowsRead: state.priorPostingRowsRead,
            compactBalanceRowsRead: compactBalanceRowsRead,
            journalEntriesChanged: state.journalEntriesChanged
        )
    }

    private func apply(
        _ record: RecordWrite,
        updatedAt: TimeInterval,
        state: inout WriteTransactionState
    ) throws {
        if record.collection == .journalEntries {
            let prior = try postingTotals(forEntryID: record.id)
            state.priorPostingRowsRead += prior.rowCount
            try merge(prior.totals, subtractingFrom: &state.balanceDeltas)
            state.journalEntriesChanged += 1
            if let key = try journalIntelligencePayeeKey(entryID: record.id) {
                state.affectedPayeeKeys.insert(key)
            }
        }
        try upsertRecord(
            collection: record.collection.rawValue,
            recordID: record.id,
            payload: record.payload,
            updatedAt: updatedAt,
            indexedAt: record.indexedAt
        )
        if record.collection == .journalEntries {
            try replaceJournalIndex(entryID: record.id, with: record.journalIndex)
            try merge(
                postingTotals(for: record.journalIndex),
                addingTo: &state.balanceDeltas
            )
            if try intelligenceIndexingEnabled(), let index = record.journalIndex {
                try replaceJournalIntelligenceSource(entryID: record.id, with: index)
                if let key = index.normalizedPayeeKey {
                    state.affectedPayeeKeys.insert(key)
                }
            }
        }
        if record.collection == .accounts,
           let accountIndex = record.ledgerAccountIndex,
           try intelligenceIndexingEnabled() {
            try replaceLedgerAccountIntelligenceIndex(
                accountID: record.id,
                with: accountIndex
            )
            state.accountIntelligenceChanged = true
        }
        if record.collection == .receiptAttachments,
           let attachmentIndex = record.receiptAttachmentIndex {
            try replaceReceiptAttachmentIndex(
                attachmentID: record.id,
                with: attachmentIndex
            )
        }
        if record.collection == .budgetEntryAttributions,
           let attributionIndex = record.budgetAttributionIndex {
            try replaceBudgetAttributionIndex(
                entryID: record.id,
                with: attributionIndex
            )
        }
        if let preference = record.profileIntelligenceEnabled {
            state.intelligencePreference = preference
        }
    }

    private func apply(
        _ deletion: RecordDeletion,
        state: inout WriteTransactionState
    ) throws {
        if deletion.collection == .journalEntries {
            let prior = try postingTotals(forEntryID: deletion.id)
            state.priorPostingRowsRead += prior.rowCount
            try merge(prior.totals, subtractingFrom: &state.balanceDeltas)
            state.journalEntriesChanged += 1
            if let key = try journalIntelligencePayeeKey(entryID: deletion.id) {
                state.affectedPayeeKeys.insert(key)
            }
            try deleteJournalIndex(entryID: deletion.id)
        }
        if deletion.collection == .accounts,
           try intelligenceIndexingEnabled() {
            try deleteLedgerAccountIntelligenceIndex(accountID: deletion.id)
            state.accountIntelligenceChanged = true
        }
        if deletion.collection == .receiptAttachments {
            try deleteReceiptAttachmentIndex(attachmentID: deletion.id)
        }
        if deletion.collection == .budgetEntryAttributions {
            try deleteBudgetAttributionIndex(entryID: deletion.id)
        }
        try remove(
            collection: deletion.collection.rawValue,
            recordID: deletion.id
        )
        if deletion.collection == .profile,
           deletion.id == UserProfile.primaryRecordID {
            state.intelligencePreference = true
        }
    }

    private func finalizeIntelligenceWrite(
        _ state: WriteTransactionState
    ) throws {
        if state.intelligencePreference != nil {
            try rebuildAllIntelligenceIndexesFromRecords()
            return
        }
        guard try intelligenceIndexingEnabled() else { return }
        if state.accountIntelligenceChanged {
            for key in try indexedPayeeKeys() {
                try rebuildPayeeAffinity(for: key)
            }
            return
        }
        for key in state.affectedPayeeKeys.sorted() {
            try rebuildPayeeAffinity(for: key)
        }
    }

    private func merge(
        _ totals: [BalanceKey: Decimal],
        addingTo balanceDeltas: inout [BalanceKey: Decimal]
    ) throws {
        for (key, amount) in totals {
            balanceDeltas[key] = try CheckedDecimal.adding(
                balanceDeltas[key] ?? .zero,
                amount
            )
        }
    }

    private func merge(
        _ totals: [BalanceKey: Decimal],
        subtractingFrom balanceDeltas: inout [BalanceKey: Decimal]
    ) throws {
        for (key, amount) in totals {
            balanceDeltas[key] = try CheckedDecimal.subtracting(
                balanceDeltas[key] ?? .zero,
                amount
            )
        }
    }

    private func rollbackFailedWrite() throws {
        do {
            #if DEBUG
            if shouldFailNextWriteRollbackForTesting {
                shouldFailNextWriteRollbackForTesting = false
                try execute("ROLLBACK TO moneyup_missing_write_savepoint;")
            }
            #endif
            try execute("ROLLBACK;")
        } catch {
            close()
            throw PersistenceError.transactionStateIndeterminate
        }
    }

    func relinkReceiptAttachments(
        from sourceEntryID: UUID,
        to destinationEntryID: UUID,
        updatedAt: TimeInterval
    ) throws {
        guard sourceEntryID != destinationEntryID else { return }
        let attachmentRecordIDs = try receiptAttachmentRecordIDs(entryID: sourceEntryID)
        for attachmentRecordID in attachmentRecordIDs {
            guard let attachmentID = UUID(uuidString: attachmentRecordID) else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: attachmentRecordID
                )
            }
            guard let payload = try fetch(
                collection: RecordCollection.receiptAttachments.rawValue,
                recordID: attachmentRecordID
            ) else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: attachmentRecordID
                )
            }
            let original: ReceiptAttachment
            do {
                original = try JSONDecoder().decode(ReceiptAttachment.self, from: payload)
            } catch {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: attachmentRecordID
                )
            }
            guard original.id == attachmentID,
                  original.entryID == sourceEntryID else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: attachmentRecordID
                )
            }
            let relinked = try ReceiptAttachment(
                id: original.id,
                entryID: destinationEntryID,
                mediaType: original.mediaType,
                data: original.data,
                createdAt: original.createdAt,
                displayName: original.displayName,
                searchText: original.searchText,
                classificationLabels: original.classificationLabels
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let relinkedPayload = try encoder.encode(relinked)
            let index = ReceiptAttachmentIndexWrite(
                attachment: relinked,
                recordID: attachmentRecordID
            )
            try upsertRecord(
                collection: RecordCollection.receiptAttachments.rawValue,
                recordID: attachmentRecordID,
                payload: relinkedPayload,
                updatedAt: updatedAt,
                indexedAt: nil
            )
            try replaceReceiptAttachmentIndex(
                attachmentID: attachmentRecordID,
                with: index
            )
        }
    }

    func replaceReceiptAttachmentIndex(
        attachmentID: String,
        with index: ReceiptAttachmentIndexWrite
    ) throws {
        guard index.recordID == attachmentID,
              index.byteCount > 0,
              index.byteCount <= ReceiptAttachment.maximumByteCount,
              index.createdAt.isFinite,
              UUID(uuidString: index.entryID) != nil,
              ReceiptAttachmentMediaType(rawValue: index.mediaType) != nil else {
            throw PersistenceError.invalidStoredRecord(
                collection: .receiptAttachments,
                recordID: attachmentID
            )
        }
        try upsertReceiptAttachmentIndex(
            attachmentID: attachmentID,
            index: index
        )
        receiptAttachmentSearchCache = nil
    }

    func upsertReceiptAttachmentIndex(
        attachmentID: String,
        index: ReceiptAttachmentIndexWrite
    ) throws {
        try withStatement(
            """
            INSERT INTO receipt_attachment_index (
                attachment_id, entry_id, media_type, byte_count, created_at,
                display_name, search_index_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(attachment_id) DO UPDATE SET
                entry_id = excluded.entry_id,
                media_type = excluded.media_type,
                byte_count = excluded.byte_count,
                created_at = excluded.created_at,
                display_name = excluded.display_name,
                search_index_text = excluded.search_index_text;
            """
        ) { statement in
            try bindText(attachmentID, at: 1, to: statement)
            try bindText(index.entryID, at: 2, to: statement)
            try bindText(index.mediaType, at: 3, to: statement)
            guard sqlite3_bind_int64(statement, 4, sqlite3_int64(index.byteCount)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 5, index.createdAt) == SQLITE_OK else {
                throw makeError()
            }
            try bindOptionalText(index.displayName, at: 6, to: statement)
            try bindOptionalText(index.searchIndexText, at: 7, to: statement)
            try stepExpectingDone(statement)
        }
    }

    func deleteReceiptAttachmentIndex(attachmentID: String) throws {
        try withStatement(
            "DELETE FROM receipt_attachment_index WHERE attachment_id = ?;"
        ) { statement in
            try bindText(attachmentID, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
        receiptAttachmentSearchCache = nil
    }

    func replaceBudgetAttributionIndex(
        entryID: String,
        with index: BudgetAttributionIndexWrite?
    ) throws {
        try deleteBudgetAttributionIndex(entryID: entryID)
        guard let index,
              index.recordID == entryID,
              index.occurredAt.isFinite,
              index.originDayKey > 0 else { return }
        try withStatement(
            """
            INSERT INTO budget_attribution_entry_index (
                entry_id, occurred_at, origin_day_key, integrity_fingerprint
            ) VALUES (?, ?, ?, ?);
            """
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try bindDouble(index.occurredAt, at: 2, to: statement)
            guard sqlite3_bind_int64(
                statement,
                3,
                Int64(index.originDayKey)
            ) == SQLITE_OK else { throw makeError() }
            try bindBlob(index.integrityFingerprint, at: 4, to: statement)
            try stepExpectingDone(statement)
        }
        for (postingIndex, posting) in index.postings.enumerated() {
            if postingIndex.isMultiple(of: 128) { try Task.checkCancellation() }
            try withStatement(
                """
                INSERT INTO budget_attribution_posting_index (
                    entry_id, posting_id, account_id, currency, amount_text
                ) VALUES (?, ?, ?, ?, ?);
                """
            ) { statement in
                try bindText(entryID, at: 1, to: statement)
                try bindText(posting.postingID, at: 2, to: statement)
                try bindText(posting.accountID, at: 3, to: statement)
                try bindText(posting.currency, at: 4, to: statement)
                try bindText(posting.amount, at: 5, to: statement)
                try stepExpectingDone(statement)
            }
        }
    }

    func deleteBudgetAttributionIndex(entryID: String) throws {
        try withStatement(
            "DELETE FROM budget_attribution_entry_index WHERE entry_id = ?;"
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
    }
}
