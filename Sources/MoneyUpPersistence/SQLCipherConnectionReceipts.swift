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
            SELECT attachment_id, entry_id, media_type, byte_count, created_at,
                   display_name
            FROM receipt_attachment_index
            ORDER BY created_at ASC, attachment_id ASC;
            """
        ) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                guard let row = try receiptAttachmentMetadataRow(statement) else { continue }
                canonicalIndexedRecordIDs.insert(row.recordID)
                metadata.append(row.metadata)
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

    private func receiptAttachmentMetadataRow(
        _ statement: OpaquePointer
    ) throws -> (recordID: String, metadata: ReceiptAttachmentMetadata)? {
        guard let rawAttachmentID = sqlite3_column_text(statement, 0),
              let rawEntryID = sqlite3_column_text(statement, 1),
              let rawMediaType = sqlite3_column_text(statement, 2) else {
            throw makeError(code: SQLITE_CORRUPT)
        }
        let recordID = String(cString: rawAttachmentID)
        guard let attachmentID = UUID(uuidString: recordID),
              attachmentID.uuidString == recordID,
              let entryID = UUID(uuidString: String(cString: rawEntryID)),
              let mediaType = ReceiptAttachmentMediaType(
                rawValue: String(cString: rawMediaType)
              ) else { return nil }
        return (
            recordID,
            try ReceiptAttachmentMetadata(
                id: attachmentID,
                entryID: entryID,
                mediaType: mediaType,
                byteCount: Int(sqlite3_column_int64(statement, 3)),
                createdAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 4)
                ),
                displayName: sqlite3_column_text(statement, 5).map {
                    String(cString: $0)
                }
            )
        )
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

    func receiptAttachmentSearchMatches(
        query: String
    ) throws -> [ReceiptAttachmentSearchMatch] {
        guard let normalizedQuery = PayeeNormalization.boundedIndexKey(query),
              PayeeNormalization.isMeaningful(normalizedQuery) else { return [] }
        if receiptAttachmentSearchCache?.query == normalizedQuery {
            return receiptAttachmentSearchCache?.matches ?? []
        }
        let matches = try withStatement(
            """
            SELECT entry_id, attachment_id, media_type, display_name
            FROM receipt_attachment_index
            WHERE search_index_text IS NOT NULL
              AND instr(search_index_text, ?) > 0
            ORDER BY created_at DESC, attachment_id DESC;
            """
        ) { statement in
            try bindText(normalizedQuery, at: 1, to: statement)
            var matches: [ReceiptAttachmentSearchMatch] = []
            var seenEntryIDs = Set<UUID>()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawEntryID = sqlite3_column_text(statement, 0),
                      let rawAttachmentID = sqlite3_column_text(statement, 1),
                      let rawMediaType = sqlite3_column_text(statement, 2),
                      let entryID = UUID(uuidString: String(cString: rawEntryID)),
                      entryID.uuidString == String(cString: rawEntryID),
                      let attachmentID = UUID(uuidString: String(cString: rawAttachmentID)),
                      attachmentID.uuidString == String(cString: rawAttachmentID),
                      let mediaType = ReceiptAttachmentMediaType(
                        rawValue: String(cString: rawMediaType)
                      ) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                // One concise reason per transaction is enough for History.
                guard seenEntryIDs.insert(entryID).inserted else { continue }
                matches.append(
                    ReceiptAttachmentSearchMatch(
                        entryID: entryID,
                        attachmentID: attachmentID,
                        mediaType: mediaType,
                        displayName: sqlite3_column_text(statement, 3).map {
                            String(cString: $0)
                        }
                    )
                )
            }
            return matches
        }
        receiptAttachmentSearchCache = (normalizedQuery, matches)
        return matches
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
                try execute("DELETE FROM payee_affinity_index;")
                try execute("DELETE FROM journal_entry_index;")
                try execute("DELETE FROM journal_balance;")
            }
            if collection == RecordCollection.accounts.rawValue {
                try execute("DELETE FROM payee_affinity_index;")
                try execute("DELETE FROM ledger_account_intelligence_index;")
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
            if collection == RecordCollection.profile.rawValue {
                try rebuildAllIntelligenceIndexesFromRecords()
            }
            try execute("COMMIT;")
            if collection == RecordCollection.receiptAttachments.rawValue {
                receiptAttachmentSearchCache = nil
            }
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
}
