import Foundation
import MoneyUpCore
import SQLCipher

extension EncryptedRecordStore {
    public func journalLedgerIndex(
        validAccountIDs: Set<UUID>,
        expectedAccountCurrencies: [UUID: CurrencyCode] = [:],
        excludingEntryIDs: Set<UUID> = []
    ) throws -> JournalLedgerIndexSnapshot {
        let validIDs = Set(validAccountIDs.map(\.uuidString))
        let expectedCurrencies = Dictionary(
            uniqueKeysWithValues: expectedAccountCurrencies.map {
                ($0.key.uuidString, $0.value.value)
            }
        )
        let missingIndexIDs = try connection.fetchUnindexedJournalRecordIDs()
        let structurallyInvalidEntryStrings = try invalidJournalEntryStrings(
            validAccountIDs: validIDs,
            expectedAccountCurrencies: expectedCurrencies,
            missingIndexIDs: missingIndexIDs
        )
        let existingExcludedEntryStrings = Set(
            try connection.fetchExistingJournalEntryIDs(
                excludingEntryIDs.map(\.uuidString)
            )
        )
        let invalidEntryStrings = structurallyInvalidEntryStrings.union(
            existingExcludedEntryStrings
        )
        // Exact Decimal subtraction is needed only for quarantined entries.
        // Healthy books therefore materialize zero historical posting rows.
        let quarantinedPostingRows = try connection.fetchQuarantinedJournalPostings(
            entryIDs: invalidEntryStrings
        )
        let referenceRows = try connection.fetchJournalReferenceCounts(
            validAccountIDs: validIDs
        )
        let decimalBalances = try journalDecimalBalances(
            quarantinedPostingRows: quarantinedPostingRows
        )
        let balances = try journalMoneyBalances(
            decimalBalances,
            validAccountIDs: validAccountIDs
        )
        let referenceCounts = journalReferenceCounts(
            referenceRows,
            quarantinedPostingRows: quarantinedPostingRows
        )
        let invalidRelationshipIDs = Set(
            invalidEntryStrings.compactMap { UUID(uuidString: $0) }
        )
        let issues = missingIndexIDs.map {
            RecordDecodeIssue(collection: .journalEntries, recordID: $0)
        } + structurallyInvalidEntryStrings.sorted().map {
            RecordDecodeIssue(collection: .journalEntries, recordID: $0)
        }
        connection.lastJournalLedgerReadDiagnostics = JournalLedgerReadDiagnostics(
            invalidEntryIDsRead: invalidEntryStrings.count,
            quarantinedPostingRowsRead: quarantinedPostingRows.count,
            referenceAggregateRowsRead: referenceRows.count
        )
        return JournalLedgerIndexSnapshot(
            entryCount: try connection.count(
                collection: RecordCollection.journalEntries.rawValue
            ) - Set(missingIndexIDs).union(invalidEntryStrings).count,
            balances: balances,
            referenceCounts: referenceCounts,
            issues: issues,
            invalidRelationshipEntryIDs: invalidRelationshipIDs
        )
    }

    private func invalidJournalEntryStrings(
        validAccountIDs: Set<String>,
        expectedAccountCurrencies: [String: String],
        missingIndexIDs: [String]
    ) throws -> Set<String> {
        var invalid = try connection.fetchInvalidJournalEntryIDs(
            validAccountIDs: validAccountIDs,
            expectedAccountCurrencies: expectedAccountCurrencies
        )
        invalid.formUnion(try connection.fetchNoncanonicalJournalEntryIDs())
        // A lowercase alias is deliberately unindexed. Quarantine its indexed
        // canonical physical twin too, so no ambiguous transaction is exposed.
        let canonicalTwins = missingIndexIDs.compactMap { recordID -> String? in
            guard let id = UUID(uuidString: recordID), id.uuidString != recordID else {
                return nil
            }
            return id.uuidString
        }
        invalid.formUnion(try connection.fetchExistingJournalEntryIDs(canonicalTwins))
        return invalid
    }

    private func journalDecimalBalances(
        quarantinedPostingRows: [IndexedPostingRow]
    ) throws -> [String: [String: Decimal]] {
        var balances: [String: [String: Decimal]] = [:]
        for row in try connection.fetchJournalBalances() {
            guard let amount = Decimal(
                string: row.amount,
                locale: Locale(identifier: "en_US_POSIX")
            ) else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .journalEntries,
                    recordID: "balance-index"
                )
            }
            balances[row.accountID.lowercased(), default: [:]][row.currency] = amount
        }
        // A relationship error quarantines the complete balanced entry.
        for row in quarantinedPostingRows {
            guard let amount = Decimal(
                string: row.amount,
                locale: Locale(identifier: "en_US_POSIX")
            ) else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .journalEntries,
                    recordID: row.entryID
                )
            }
            let accountID = row.accountID.lowercased()
            var accountBalances = balances[accountID] ?? [:]
            accountBalances[row.currency] = try CheckedDecimal.subtracting(
                accountBalances[row.currency] ?? .zero,
                amount
            )
            balances[accountID] = accountBalances
        }
        return balances
    }

    private func journalMoneyBalances(
        _ decimalBalances: [String: [String: Decimal]],
        validAccountIDs: Set<UUID>
    ) throws -> [UUID: [CurrencyCode: Money]] {
        var balances: [UUID: [CurrencyCode: Money]] = [:]
        for (rawAccountID, currencyAmounts) in decimalBalances {
            guard let accountID = UUID(uuidString: rawAccountID),
                  validAccountIDs.contains(accountID) else { continue }
            for (rawCurrency, amount) in currencyAmounts where amount != .zero {
                let currency = try CurrencyCode(rawCurrency)
                balances[accountID, default: [:]][currency] = try Money(
                    amount,
                    currency: currency
                )
            }
        }
        return balances
    }

    private func journalReferenceCounts(
        _ referenceRows: [IndexedReferenceCountRow],
        quarantinedPostingRows: [IndexedPostingRow]
    ) -> [UUID: Int] {
        var invalidReferences: [String: Set<String>] = [:]
        for row in quarantinedPostingRows {
            // Physical journal identities are binary keys. Preserve spelling.
            invalidReferences[row.accountID.lowercased(), default: []].insert(row.entryID)
        }
        var counts: [UUID: Int] = [:]
        for row in referenceRows {
            guard let accountID = UUID(uuidString: row.accountID) else { continue }
            counts[accountID] = max(
                0,
                row.count - invalidReferences[row.accountID.lowercased(), default: []].count
            )
        }
        return counts
    }

    public func containsJournalEntry(sourceFingerprint: String) throws -> Bool {
        try connection.containsJournalEntry(sourceFingerprint: sourceFingerprint)
    }

    /// Resolves only the journal identities referenced by another collection.
    /// This keeps attachment validation proportional to attachment count and
    /// never decodes (or returns IDs for) the rest of the journal.
    public func existingJournalEntryIDs(
        in candidateIDs: Set<UUID>
    ) throws -> Set<UUID> {
        let rawIDs = candidateIDs.map(\.uuidString)
        return Set(
            try connection.fetchExistingJournalEntryIDs(rawIDs)
                .compactMap { UUID(uuidString: $0) }
        )
    }

    /// Compact global duplicate identity read for explicit import/reconcile
    /// operations. It does not decode journal JSON.
    public func journalSourceFingerprints() throws -> Set<String> {
        try connection.fetchJournalSourceFingerprints()
    }

    public func journalIndexDiagnostics() throws -> JournalIndexDiagnostics {
        try connection.journalIndexDiagnostics()
    }

    public func lastJournalWriteDiagnostics() -> JournalWriteDiagnostics {
        connection.lastJournalWriteDiagnostics
    }

    public func lastJournalLedgerReadDiagnostics() -> JournalLedgerReadDiagnostics {
        connection.lastJournalLedgerReadDiagnostics
    }

    /// Internal runtime evidence for the persistence security tests. Startup
    /// also fails closed if SQLCipher does not retain this configuration.
    func usesMemoryOnlyTemporaryStorage() throws -> Bool {
        try connection.usesMemoryOnlyTemporaryStorage()
    }

    public func snapshot() throws -> DatabaseSnapshot {
        DatabaseSnapshot(
            schemaVersion: connection.schemaVersion(),
            records: try connection.fetchAllRecords()
        )
    }

    public func storageMetrics() throws -> DatabaseStorageMetrics {
        try connection.storageMetrics()
    }

    /// Reduces raw records under this store actor's isolation without ever
    /// materializing the complete database snapshot. The synchronous reducer
    /// receives one bounded row at a time in stable physical-key order; it
    /// cannot suspend or interleave a store mutation while its cursor is open.
    public func reduceStoredRecords<State: Sendable>(
        into initialState: State,
        _ updateAccumulatingResult: @Sendable (
            inout State,
            StoredRecordSnapshot,
            Int
        ) throws -> Void
    ) throws -> State {
        try connection.reduceAllRecords(
            into: initialState,
            updateAccumulatingResult
        )
    }

    /// Creates the current portable archive directly from the encrypted SQL
    /// cursor. At most one bounded record and one encryption chunk are resident
    /// at a time; the complete book is never copied into a process array.
    public func exportPortableArchive(
        to destinationURL: URL,
        password: String
    ) throws {
        let performanceInterval = MoneyUpPerformanceSignposts.begin(.archiveExport)
        defer { MoneyUpPerformanceSignposts.end(performanceInterval) }
        try connection.exportPortableArchive(
            to: destinationURL,
            password: password
        )
    }

    /// Replaces the complete logical store from an authenticated archive in
    /// one SQLite transaction. Every version-2 record is decoded and indexed
    /// incrementally; any authentication, validation, cancellation, or write
    /// failure rolls the entire candidate back.
    @discardableResult
    public func restorePortableArchive(
        from sourceURL: URL,
        password: String,
        observesCancellation: Bool = true
    ) throws -> PortableArchiveRestoreMetadata {
        let performanceInterval = MoneyUpPerformanceSignposts.begin(.archiveRestore)
        defer { MoneyUpPerformanceSignposts.end(performanceInterval) }
        return try connection.replaceAllRecords(
            fromPortableArchive: sourceURL,
            password: password,
            observesCancellation: observesCancellation
        )
    }

    /// Replaces the complete logical store in one SQLite transaction.
    /// Callers must decrypt and validate the candidate before invoking this.
    public func restore(
        _ snapshot: DatabaseSnapshot,
        observesCancellation: Bool = true
    ) throws {
        guard snapshot.schemaVersion > 0 else {
            throw PersistenceError.invalidSnapshot
        }
        guard snapshot.schemaVersion <= Self.currentSchemaVersion else {
            throw PersistenceError.unsupportedSchema(
                found: snapshot.schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard snapshot.createdAt.timeIntervalSince1970.isFinite else {
            throw PersistenceError.invalidSnapshot
        }
        try connection.replaceAllRecords(
            with: snapshot.records,
            observesCancellation: observesCancellation
        )
    }

    public func remove(id: String, from collection: RecordCollection) throws {
        try connection.write(
            [],
            removing: [RecordDeletion(id: id, from: collection)]
        )
    }

    public func removeAll(from collection: RecordCollection) throws {
        try connection.removeAll(collection: collection.rawValue)
    }

    public func count(in collection: RecordCollection) throws -> Int {
        try connection.count(collection: collection.rawValue)
    }

    public func recordCountSnapshot() throws -> DatabaseRecordCountSnapshot {
        let pairs = try RecordCollection.allCases.map { collection in
            (
                collection.rawValue,
                try connection.count(collection: collection.rawValue)
            )
        }
        return DatabaseRecordCountSnapshot(
            schemaVersion: connection.schemaVersion(),
            storedRecordCounts: Dictionary(uniqueKeysWithValues: pairs)
        )
    }

    #if DEBUG
    /// Recreates the case-insensitive identity indexes emitted by pre-audit
    /// builds so regression tests can exercise upgrade quarantine against a
    /// real legacy database shape. It is unavailable in release builds.
    func installLegacyCaseVariantIndexesForTesting() throws {
        try connection.installLegacyCaseVariantIndexesForTesting()
    }

    func failNextRestoreRollbackForTesting() {
        connection.failNextRestoreRollbackForTesting()
    }

    func failNextWriteRollbackForTesting() {
        connection.failNextWriteRollbackForTesting()
    }

    func installSchema6IntelligenceStateForTesting() throws {
        try connection.installSchema6IntelligenceStateForTesting()
    }

    func installSchema8EvidenceStateForTesting() throws {
        try connection.installSchema8EvidenceStateForTesting()
    }
    #endif

    public func close() {
        connection.close()
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
