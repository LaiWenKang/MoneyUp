import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func receiptAttachmentIndexSnapshot() throws
        -> ReceiptAttachmentIndexSnapshot {
        var metadata: [ReceiptAttachmentMetadata] = []
        var canonicalIndexedRecordIDs = Set<String>()
        try withStatement(
            """
            SELECT attachment_id, entry_id, media_type, byte_count, created_at
            FROM receipt_attachment_index
            ORDER BY created_at ASC, attachment_id ASC;
            """
        ) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawAttachmentID = sqlite3_column_text(statement, 0),
                      let rawEntryID = sqlite3_column_text(statement, 1),
                      let rawMediaType = sqlite3_column_text(statement, 2)
                else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                let attachmentRecordID = String(cString: rawAttachmentID)
                guard let attachmentID = UUID(uuidString: attachmentRecordID),
                      attachmentID.uuidString == attachmentRecordID,
                      let entryID = UUID(uuidString: String(cString: rawEntryID)),
                      let mediaType = ReceiptAttachmentMediaType(
                        rawValue: String(cString: rawMediaType)
                      ) else { continue }
                canonicalIndexedRecordIDs.insert(attachmentRecordID)
                metadata.append(
                    try ReceiptAttachmentMetadata(
                        id: attachmentID,
                        entryID: entryID,
                        mediaType: mediaType,
                        byteCount: Int(sqlite3_column_int64(statement, 3)),
                        createdAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(statement, 4)
                        )
                    )
                )
            }
        }

        let issues = try withStatement(
            """
            SELECT record_id
            FROM records
            WHERE collection = ?
            ORDER BY record_id ASC;
            """
        ) { statement in
            try bindText(
                RecordCollection.receiptAttachments.rawValue,
                at: 1,
                to: statement
            )
            var issues: [RecordDecodeIssue] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                let recordID = String(cString: rawID)
                if !canonicalIndexedRecordIDs.contains(recordID) {
                    issues.append(
                        RecordDecodeIssue(
                            collection: .receiptAttachments,
                            recordID: recordID
                        )
                    )
                }
            }
            return issues
        }
        lastReceiptAttachmentReadDiagnostics = ReceiptAttachmentReadDiagnostics(
            metadataRowsRead: metadata.count,
            blobPayloadsDecoded: 0
        )
        return ReceiptAttachmentIndexSnapshot(metadata: metadata, issues: issues)
    }

    func receiptAttachment(id: UUID) throws -> ReceiptAttachment? {
        let attachment: ReceiptAttachment? = try withStatement(
            """
            SELECT records.payload,
                   receipt_attachment_index.entry_id,
                   receipt_attachment_index.media_type,
                   receipt_attachment_index.byte_count,
                   receipt_attachment_index.created_at
            FROM receipt_attachment_index
            JOIN records
              ON records.collection = ?
             AND records.record_id = receipt_attachment_index.attachment_id
            WHERE receipt_attachment_index.attachment_id = ?;
            """
        ) { statement in
            try bindText(
                RecordCollection.receiptAttachments.rawValue,
                at: 1,
                to: statement
            )
            try bindText(id.uuidString, at: 2, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW,
                  let rawEntryID = sqlite3_column_text(statement, 1),
                  let rawMediaType = sqlite3_column_text(statement, 2),
                  let entryID = UUID(uuidString: String(cString: rawEntryID)),
                  let mediaType = ReceiptAttachmentMediaType(
                    rawValue: String(cString: rawMediaType)
                  ) else {
                throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
            }
            let attachment: ReceiptAttachment
            do {
                attachment = try JSONDecoder().decode(
                    ReceiptAttachment.self,
                    from: data(from: statement, column: 0)
                )
            } catch {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: id.uuidString
                )
            }
            guard attachment.id == id,
                  attachment.entryID == entryID,
                  attachment.mediaType == mediaType,
                  attachment.data.count == Int(sqlite3_column_int64(statement, 3)),
                  abs(
                    attachment.createdAt.timeIntervalSince1970
                        - sqlite3_column_double(statement, 4)
                  ) <= 0.000_001 else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: id.uuidString
                )
            }
            return attachment
        }
        lastReceiptAttachmentReadDiagnostics = ReceiptAttachmentReadDiagnostics(
            metadataRowsRead: attachment == nil ? 0 : 1,
            blobPayloadsDecoded: attachment == nil ? 0 : 1
        )
        return attachment
    }

    func receiptAttachmentIDs(entryID: UUID) throws -> [UUID] {
        try receiptAttachmentRecordIDs(entryID: entryID).map { recordID in
            guard let id = UUID(uuidString: recordID),
                  id.uuidString == recordID else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .receiptAttachments,
                    recordID: recordID
                )
            }
            return id
        }
    }

    func receiptAttachmentRecordIDs(entryID: UUID) throws -> [String] {
        try withStatement(
            """
            SELECT attachment_id
            FROM receipt_attachment_index
            WHERE entry_id = ?
            ORDER BY created_at ASC, attachment_id ASC;
            """
        ) { statement in
            try bindText(entryID.uuidString, at: 1, to: statement)
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

    func remove(collection: String, recordID: String) throws {
        try withStatement(
            "DELETE FROM records WHERE collection = ? AND record_id = ?;"
        ) { statement in
            try bindText(collection, at: 1, to: statement)
            try bindText(recordID, at: 2, to: statement)
            try stepExpectingDone(statement)
        }
    }

    func removeAll(collection: String) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            if collection == RecordCollection.journalEntries.rawValue {
                try execute("DELETE FROM journal_entry_index;")
                try execute("DELETE FROM journal_balance;")
            }
            if collection == RecordCollection.receiptAttachments.rawValue {
                try execute("DELETE FROM receipt_attachment_index;")
            }
            if collection == RecordCollection.budgetEntryAttributions.rawValue {
                try execute("DELETE FROM budget_attribution_entry_index;")
            }
            try withStatement("DELETE FROM records WHERE collection = ?;") { statement in
                try bindText(collection, at: 1, to: statement)
                try stepExpectingDone(statement)
            }
            try execute("COMMIT;")
        } catch let operationError {
            do {
                try execute("ROLLBACK;")
            } catch {
                close()
                throw PersistenceError.transactionStateIndeterminate
            }
            throw operationError
        }
    }

    func count(collection: String) throws -> Int {
        try withStatement(
            "SELECT COUNT(*) FROM records WHERE collection = ?;"
        ) { statement in
            try bindText(collection, at: 1, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func storageMetrics() throws -> DatabaseStorageMetrics {
        try withStatement(
            """
            SELECT record_count,
                   payload_byte_count,
                   record_id_byte_count,
                   collection_byte_count
            FROM store_metrics
            WHERE singleton = 1;
            """
        ) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            let recordCount = sqlite3_column_int64(statement, 0)
            let payloadByteCount = sqlite3_column_int64(statement, 1)
            let recordIDByteCount = sqlite3_column_int64(statement, 2)
            let collectionByteCount = sqlite3_column_int64(statement, 3)
            guard recordCount >= 0,
                  payloadByteCount >= 0,
                  recordIDByteCount >= 0,
                  collectionByteCount >= 0,
                  recordCount <= Int64(Int.max),
                  payloadByteCount <= Int64(Int.max),
                  recordIDByteCount <= Int64(Int.max),
                  collectionByteCount <= Int64(Int.max) else {
                throw makeError(code: SQLITE_TOOBIG)
            }
            return DatabaseStorageMetrics(
                recordCount: Int(recordCount),
                payloadByteCount: Int(payloadByteCount),
                recordIDByteCount: Int(recordIDByteCount),
                collectionByteCount: Int(collectionByteCount)
            )
        }
    }

    func exportPortableArchive(
        to destinationURL: URL,
        password: String
    ) throws {
        let metrics = try storageMetrics()
        try PortableArchiveV2.seal(
            schemaVersion: schemaVersion(),
            createdAt: Date(),
            metrics: metrics,
            password: password,
            to: destinationURL
        ) { consume in
            try enumerateAllRecords(consume)
        }
    }

    func schemaVersion() -> Int32 {
        supportedSchemaVersion
    }

    func fetchAllRecords() throws -> [StoredRecordSnapshot] {
        try withStatement(
            """
            SELECT collection, record_id, payload, updated_at
            FROM records
            ORDER BY collection ASC, record_id ASC;
            """
        ) { statement in
            var records: [StoredRecordSnapshot] = []
            var rowIndex = 0
            while true {
                if rowIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawCollection = sqlite3_column_text(statement, 0),
                      let rawID = sqlite3_column_text(statement, 1) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                records.append(
                    StoredRecordSnapshot(
                        collection: String(cString: rawCollection),
                        recordID: String(cString: rawID),
                        payload: data(from: statement, column: 2),
                        updatedAt: sqlite3_column_double(statement, 3)
                    )
                )
                rowIndex += 1
            }
            return records
        }
    }

    func enumerateAllRecords(
        _ consume: (StoredRecordSnapshot) throws -> Void
    ) throws {
        try withStatement(
            """
            SELECT collection, record_id, payload, updated_at
            FROM records
            ORDER BY collection ASC, record_id ASC;
            """
        ) { statement in
            var rowIndex = 0
            while true {
                if rowIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawCollection = sqlite3_column_text(statement, 0),
                      let rawID = sqlite3_column_text(statement, 1) else {
                    throw makeError(
                        code: result == SQLITE_ROW ? SQLITE_CORRUPT : result
                    )
                }
                try consume(StoredRecordSnapshot(
                    collection: String(cString: rawCollection),
                    recordID: String(cString: rawID),
                    payload: data(from: statement, column: 2),
                    updatedAt: sqlite3_column_double(statement, 3)
                ))
                rowIndex += 1
            }
        }
    }

    func replaceAllRecords(
        fromPortableArchive sourceURL: URL,
        password: String,
        observesCancellation: Bool
    ) throws {
        let allowedCollections = Set(RecordCollection.allCases.map(\.rawValue))
        var identities = Set<String>()
        var affectedBalances = Set<BalanceKey>()
        var restoredRecordCount = 0

        if observesCancellation { try Task.checkCancellation() }
        try execute("BEGIN IMMEDIATE;")
        do {
            try clearRecordsForReplacement()
            let metadata = try PortableArchiveV2.read(
                from: sourceURL,
                password: password
            ) { record in
                if observesCancellation,
                   restoredRecordCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                try self.validateReplacementRecord(
                    record,
                    allowedCollections: allowedCollections,
                    identities: &identities
                )
                try self.insertReplacementRecord(
                    record,
                    affectedBalances: &affectedBalances,
                    observesCancellation: observesCancellation
                )
                restoredRecordCount += 1
            }
            guard metadata.schemaVersion > 0 else {
                throw PersistenceError.invalidSnapshot
            }
            guard metadata.schemaVersion <= supportedSchemaVersion else {
                throw PersistenceError.unsupportedSchema(
                    found: metadata.schemaVersion,
                    supported: supportedSchemaVersion
                )
            }
            guard metadata.createdAt.timeIntervalSince1970.isFinite,
                  restoredRecordCount == metadata.recordCount else {
                throw PersistenceError.invalidSnapshot
            }
            try enforceLogicalStoreLimits(before: nil, after: storageMetrics())
            try rebuildBalances(
                for: affectedBalances,
                observesCancellation: observesCancellation
            )
            if observesCancellation { try Task.checkCancellation() }
            try execute("COMMIT;")
        } catch let operationError {
            try rollbackReplacement(orThrowing: operationError)
        }
    }

    func replaceAllRecords(
        with records: [StoredRecordSnapshot],
        observesCancellation: Bool
    ) throws {
        let allowedCollections = Set(RecordCollection.allCases.map(\.rawValue))
        var identities = Set<String>()
        for (index, record) in records.enumerated() {
            if observesCancellation && index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            try validateReplacementRecord(
                record,
                allowedCollections: allowedCollections,
                identities: &identities
            )
        }

        if observesCancellation { try Task.checkCancellation() }
        try execute("BEGIN IMMEDIATE;")
        do {
            try clearRecordsForReplacement()
            var affectedBalances = Set<BalanceKey>()
            for (index, record) in records.enumerated() {
                if observesCancellation && index.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                try insertReplacementRecord(
                    record,
                    affectedBalances: &affectedBalances,
                    observesCancellation: observesCancellation
                )
            }
            try enforceLogicalStoreLimits(before: nil, after: storageMetrics())
            try rebuildBalances(
                for: affectedBalances,
                observesCancellation: observesCancellation
            )
            if observesCancellation { try Task.checkCancellation() }
            try execute("COMMIT;")
        } catch let operationError {
            try rollbackReplacement(orThrowing: operationError)
        }
    }

    func clearRecordsForReplacement() throws {
        try execute("DELETE FROM journal_entry_index;")
        try execute("DELETE FROM journal_balance;")
        try execute("DELETE FROM receipt_attachment_index;")
        try execute("DELETE FROM budget_attribution_entry_index;")
        try execute("DELETE FROM records;")
    }

    func validateReplacementRecord(
        _ record: StoredRecordSnapshot,
        allowedCollections: Set<String>,
        identities: inout Set<String>
    ) throws {
        guard allowedCollections.contains(record.collection),
              !record.recordID.isEmpty,
              record.recordID.utf8.count <= RecordWrite.maximumRecordIDByteCount,
              !record.payload.isEmpty,
              record.payload.count <= RecordWrite.maximumReceiptPayloadByteCount,
              record.updatedAt.isFinite else {
            throw PersistenceError.invalidSnapshot
        }
        let identity = record.collection + "\u{1f}" + record.recordID
        guard identities.insert(identity).inserted else {
            throw PersistenceError.duplicateSnapshotRecord(
                collection: record.collection,
                recordID: record.recordID
            )
        }
    }

    func insertReplacementRecord(
        _ record: StoredRecordSnapshot,
        affectedBalances: inout Set<BalanceKey>,
        observesCancellation: Bool
    ) throws {
        let journalIndex = try journalIndexWrite(
            collection: record.collection,
            recordID: record.recordID,
            payload: record.payload
        )
        let attachmentIndex = receiptAttachmentIndexWrite(
            collection: record.collection,
            recordID: record.recordID,
            payload: record.payload
        )
        let attributionIndex = budgetAttributionIndexWrite(
            collection: record.collection,
            recordID: record.recordID,
            payload: record.payload
        )
        try upsertRecord(
            collection: record.collection,
            recordID: record.recordID,
            payload: record.payload,
            updatedAt: record.updatedAt,
            indexedAt: journalIndex?.occurredAt
        )
        if record.collection == RecordCollection.journalEntries.rawValue {
            try replaceJournalIndex(
                entryID: record.recordID,
                with: journalIndex,
                observesCancellation: observesCancellation
            )
            affectedBalances.formUnion(
                journalIndex?.postings.map {
                    BalanceKey(
                        accountID: $0.accountID,
                        currency: $0.currency
                    )
                } ?? []
            )
        }
        if record.collection == RecordCollection.receiptAttachments.rawValue,
           let attachmentIndex {
            try replaceReceiptAttachmentIndex(
                attachmentID: record.recordID,
                with: attachmentIndex
            )
        }
        if record.collection
            == RecordCollection.budgetEntryAttributions.rawValue {
            try replaceBudgetAttributionIndex(
                entryID: record.recordID,
                with: attributionIndex
            )
        }
    }

    func rollbackReplacement(orThrowing operationError: Error) throws {
        do {
            #if DEBUG
            if shouldFailNextRestoreRollbackForTesting {
                shouldFailNextRestoreRollbackForTesting = false
                // Fail without ending the outer transaction so this hook
                // exercises the dangerous rollback-indeterminate state.
                try execute("ROLLBACK TO moneyup_missing_restore_savepoint;")
            }
            #endif
            try execute("ROLLBACK;")
        } catch {
            // Never leave a possibly partial transaction available to reads or
            // raw backup. Closing SQLite rolls it back durably; AppModel fails
            // closed until a fresh store is opened.
            close()
            throw PersistenceError.restoreTransactionStateIndeterminate
        }
        throw operationError
    }

    func enforceLogicalStoreLimits(
        before: DatabaseStorageMetrics?,
        after: DatabaseStorageMetrics
    ) throws {
        let isWithinLimits = after.recordCount <= PortableArchiveV2.maximumRecordCount
            && after.payloadByteCount
                <= PortableArchive.maximumStoredPayloadByteCount
        if isWithinLimits { return }

        // A pre-v5 beta book may already be above the new portable envelope.
        // Permit only monotonic cleanup until it is back inside the contract;
        // never trap a user in a state where deletion itself is impossible.
        if let before,
           (before.recordCount > PortableArchiveV2.maximumRecordCount
                || before.payloadByteCount
                    > PortableArchive.maximumStoredPayloadByteCount),
           after.recordCount <= before.recordCount,
           after.payloadByteCount <= before.payloadByteCount,
           (after.recordCount < before.recordCount
                || after.payloadByteCount < before.payloadByteCount) {
            return
        }
        throw PersistenceError.logicalStoreLimitExceeded
    }

    #if DEBUG
    func failNextRestoreRollbackForTesting() {
        shouldFailNextRestoreRollbackForTesting = true
    }

    func failNextWriteRollbackForTesting() {
        shouldFailNextWriteRollbackForTesting = true
    }

    func installLegacyCaseVariantIndexesForTesting() throws {
        let journalRecords = try fetchAll(
            collection: RecordCollection.journalEntries.rawValue
        )
        let receiptRecords = try fetchAll(
            collection: RecordCollection.receiptAttachments.rawValue
        )
        try execute("BEGIN IMMEDIATE;")
        do {
            var affectedBalances = Set<BalanceKey>()
            for record in journalRecords {
                guard let physicalID = UUID(uuidString: record.id),
                      physicalID.uuidString != record.id,
                      let entry = try? JSONDecoder().decode(
                        JournalEntry.self,
                        from: record.payload
                      ),
                      entry.id == physicalID else { continue }
                let index = JournalIndexWrite(entry: entry, recordID: record.id)
                try withStatement(
                    """
                    UPDATE records SET indexed_at = ?
                    WHERE collection = ? AND record_id = ?;
                    """
                ) { statement in
                    try bindDouble(index.occurredAt, at: 1, to: statement)
                    try bindText(
                        RecordCollection.journalEntries.rawValue,
                        at: 2,
                        to: statement
                    )
                    try bindText(record.id, at: 3, to: statement)
                    try stepExpectingDone(statement)
                }
                try replaceJournalIndex(entryID: record.id, with: index)
                affectedBalances.formUnion(index.postings.map {
                    BalanceKey(accountID: $0.accountID, currency: $0.currency)
                })
            }
            for record in receiptRecords {
                guard let physicalID = UUID(uuidString: record.id),
                      physicalID.uuidString != record.id,
                      let attachment = try? JSONDecoder().decode(
                        ReceiptAttachment.self,
                        from: record.payload
                      ),
                      attachment.id == physicalID else { continue }
                try upsertReceiptAttachmentIndex(
                    attachmentID: record.id,
                    index: ReceiptAttachmentIndexWrite(
                        attachment: attachment,
                        recordID: record.id
                    )
                )
            }
            try rebuildBalances(for: affectedBalances)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
    #endif
}
