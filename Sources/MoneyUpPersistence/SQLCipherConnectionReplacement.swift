import Foundation
import MoneyUpCore
import SQLCipher

extension SQLCipherConnection {
    func replaceAllRecords(
        fromPortableArchive sourceURL: URL,
        password: String,
        observesCancellation: Bool
    ) throws -> PortableArchiveRestoreMetadata {
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
            try rebuildAllIntelligenceIndexesFromRecords()
            if observesCancellation { try Task.checkCancellation() }
            try execute("COMMIT;")
            return PortableArchiveRestoreMetadata(
                archiveVersion: metadata.archiveVersion,
                schemaVersion: metadata.schemaVersion
            )
        } catch let operationError {
            try rollbackReplacement(orThrowing: operationError)
            throw operationError
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
            try rebuildAllIntelligenceIndexesFromRecords()
            if observesCancellation { try Task.checkCancellation() }
            try execute("COMMIT;")
        } catch let operationError {
            try rollbackReplacement(orThrowing: operationError)
        }
    }

    func clearRecordsForReplacement() throws {
        try clearIntelligenceDerivedTables()
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
