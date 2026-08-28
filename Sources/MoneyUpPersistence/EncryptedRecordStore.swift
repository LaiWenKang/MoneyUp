import Foundation
import MoneyUpCore
import SQLCipher

/// Stable keyset cursor for chronological journal paging.
///
/// The record identifier disambiguates entries with identical timestamps, so
/// inserting a newer transaction cannot shift or duplicate an already-loaded
/// page as offset pagination would.
public struct JournalEntryPageCursor: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let recordID: String

    public init(occurredAt: Date, recordID: String) {
        self.occurredAt = occurredAt
        self.recordID = recordID
    }
}

public struct JournalEntryPage: Sendable {
    public let entries: [JournalEntry]
    public let issues: [RecordDecodeIssue]
    public let nextCursor: JournalEntryPageCursor?

    public init(
        entries: [JournalEntry],
        issues: [RecordDecodeIssue],
        nextCursor: JournalEntryPageCursor?
    ) {
        self.entries = entries
        self.issues = issues
        self.nextCursor = nextCursor
    }
}

/// Compact exact state derived from the normalized encrypted journal index.
/// Its size grows with accounts/currencies, not transaction count.
public struct JournalLedgerIndexSnapshot: Sendable {
    public let entryCount: Int
    public let balances: [UUID: [CurrencyCode: Money]]
    public let referenceCounts: [UUID: Int]
    public let issues: [RecordDecodeIssue]
    public let invalidRelationshipEntryIDs: Set<UUID>

    public init(
        entryCount: Int,
        balances: [UUID: [CurrencyCode: Money]],
        referenceCounts: [UUID: Int],
        issues: [RecordDecodeIssue],
        invalidRelationshipEntryIDs: Set<UUID>
    ) {
        self.entryCount = entryCount
        self.balances = balances
        self.referenceCounts = referenceCounts
        self.issues = issues
        self.invalidRelationshipEntryIDs = invalidRelationshipEntryIDs
    }
}

public struct JournalIndexDiagnostics: Equatable, Sendable {
    public let journalRecordCount: Int
    public let indexedEntryCount: Int
    public let indexedPostingCount: Int

    public init(
        journalRecordCount: Int,
        indexedEntryCount: Int,
        indexedPostingCount: Int
    ) {
        self.journalRecordCount = journalRecordCount
        self.indexedEntryCount = indexedEntryCount
        self.indexedPostingCount = indexedPostingCount
    }
}

public struct JournalWriteDiagnostics: Equatable, Sendable {
    public let priorPostingRowsRead: Int
    public let compactBalanceRowsRead: Int
    public let journalEntriesChanged: Int

    public init(
        priorPostingRowsRead: Int,
        compactBalanceRowsRead: Int,
        journalEntriesChanged: Int
    ) {
        self.priorPostingRowsRead = priorPostingRowsRead
        self.compactBalanceRowsRead = compactBalanceRowsRead
        self.journalEntriesChanged = journalEntriesChanged
    }
}

/// Blob-free view of all receipt attachments plus identities whose encrypted
/// payload could not be represented in the normalized attachment index.
public struct ReceiptAttachmentIndexSnapshot: Sendable {
    public let metadata: [ReceiptAttachmentMetadata]
    public let issues: [RecordDecodeIssue]

    public init(
        metadata: [ReceiptAttachmentMetadata],
        issues: [RecordDecodeIssue]
    ) {
        self.metadata = metadata
        self.issues = issues
    }
}

public struct ReceiptAttachmentReadDiagnostics: Equatable, Sendable {
    public let metadataRowsRead: Int
    public let blobPayloadsDecoded: Int

    public init(metadataRowsRead: Int, blobPayloadsDecoded: Int) {
        self.metadataRowsRead = metadataRowsRead
        self.blobPayloadsDecoded = blobPayloadsDecoded
    }
}

/// Blob-free health summary for the normalized historical budget projection.
/// Healthy startup work is constant-size; only exceptional record identities
/// are returned for quarantine presentation.
public struct BudgetAttributionIndexSnapshot: Sendable {
    public let recordCount: Int
    public let indexedEntryCount: Int
    public let indexedPostingCount: Int
    public let requiresDetailedValidation: Bool
    public let issues: [RecordDecodeIssue]

    public init(
        recordCount: Int,
        indexedEntryCount: Int,
        indexedPostingCount: Int,
        requiresDetailedValidation: Bool,
        issues: [RecordDecodeIssue]
    ) {
        self.recordCount = recordCount
        self.indexedEntryCount = indexedEntryCount
        self.indexedPostingCount = indexedPostingCount
        self.requiresDetailedValidation = requiresDetailedValidation
        self.issues = issues
    }
}

/// Instrumentation for the compact ledger snapshot path. Normal reads return
/// one row per account/reference aggregate and materialize posting rows only
/// for the exceptional entries that must be quarantined as a whole.
public struct JournalLedgerReadDiagnostics: Equatable, Sendable {
    public let invalidEntryIDsRead: Int
    public let quarantinedPostingRowsRead: Int
    public let referenceAggregateRowsRead: Int

    public init(
        invalidEntryIDsRead: Int,
        quarantinedPostingRowsRead: Int,
        referenceAggregateRowsRead: Int
    ) {
        self.invalidEntryIDsRead = invalidEntryIDsRead
        self.quarantinedPostingRowsRead = quarantinedPostingRowsRead
        self.referenceAggregateRowsRead = referenceAggregateRowsRead
    }
}

/// A raw encrypted-store record used by MoneyUp's portable archive.
///
/// The payload remains the exact JSON bytes written by the originating build.
/// Keeping this layer independent of the current domain model means a recovery
/// archive can preserve a record even when a newer decoder cannot understand it.
public struct StoredRecordSnapshot: Codable, Equatable, Sendable {
    public let collection: String
    public let recordID: String
    public let payload: Data
    public let updatedAt: TimeInterval

    public init(
        collection: String,
        recordID: String,
        payload: Data,
        updatedAt: TimeInterval
    ) {
        self.collection = collection
        self.recordID = recordID
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

/// A complete point-in-time copy of the logical SQLCipher store.
public struct DatabaseSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int32
    public let createdAt: Date
    public let records: [StoredRecordSnapshot]

    public init(
        schemaVersion: Int32,
        createdAt: Date = Date(),
        records: [StoredRecordSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.records = records
    }
}

/// A point-in-time, payload-free inventory of the encrypted store.
///
/// Collection counts are read during one actor-isolated operation, so app
/// writes cannot interleave. Unlike a portable backup snapshot, this type never
/// loads journal JSON or receipt bytes into the caller.
public struct DatabaseRecordCountSnapshot: Equatable, Sendable {
    public let schemaVersion: Int32
    public let createdAt: Date
    public let storedRecordCounts: [String: Int]

    public init(
        schemaVersion: Int32,
        createdAt: Date = Date(),
        storedRecordCounts: [String: Int]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.storedRecordCounts = storedRecordCounts
    }

    public func count(in collection: RecordCollection) -> Int {
        storedRecordCounts[collection.rawValue] ?? 0
    }
}

/// Constant-memory SQL aggregates used before a portable backup snapshots any
/// payload bytes into process memory.
public struct DatabaseStorageMetrics: Equatable, Sendable {
    public let recordCount: Int
    public let payloadByteCount: Int
    public let recordIDByteCount: Int
    public let collectionByteCount: Int

    public init(
        recordCount: Int,
        payloadByteCount: Int,
        recordIDByteCount: Int,
        collectionByteCount: Int
    ) {
        self.recordCount = recordCount
        self.payloadByteCount = payloadByteCount
        self.recordIDByteCount = recordIDByteCount
        self.collectionByteCount = collectionByteCount
    }
}

public struct RecordDecodeIssue: Equatable, Sendable, Identifiable {
    public let collection: RecordCollection
    public let recordID: String

    public init(collection: RecordCollection, recordID: String) {
        self.collection = collection
        self.recordID = recordID
    }

    public var id: String { "\(collection.rawValue):\(recordID)" }
}

public struct RecoveredRecords<Value: Sendable>: Sendable {
    public let values: [Value]
    public let issues: [RecordDecodeIssue]

    public init(values: [Value], issues: [RecordDecodeIssue]) {
        self.values = values
        self.issues = issues
    }
}

private struct IndexedPayloadRecord {
    let id: String
    let payload: Data
    let indexedAt: TimeInterval
}

private struct IndexedPayloadPage {
    let records: [IndexedPayloadRecord]
    let nextCursor: JournalEntryPageCursor?
}

private struct IndexedPostingRow {
    let entryID: String
    let occurredAt: TimeInterval
    let originDayKey: Int
    let postingID: String
    let accountID: String
    let currency: String
    let amount: String
}

private struct IndexedBalanceRow {
    let accountID: String
    let currency: String
    let amount: String
}

private struct IndexedReferenceCountRow {
    let accountID: String
    let count: Int
}

/// An actor-isolated SQLCipher record store.
///
/// Each record is encoded independently as validated JSON and stored inside an
/// encrypted SQLite database. Journal entries therefore remain atomic, while
/// migrations can evolve collections without rewriting an entire user book.
public actor EncryptedRecordStore {
    public static let currentSchemaVersion: Int32 = 6

    private let connection: SQLCipherConnection

    public init(databaseURL: URL, key: Data) throws {
        guard key.count == 32 else {
            throw PersistenceError.invalidKeyLength
        }

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        #if os(iOS)
        // The database key is deliberately ThisDeviceOnly and cannot be
        // restored on another device. Excluding the ciphertext directory from
        // system backups prevents an unusable database from being restored
        // without its key. Portable recovery is provided separately by an
        // authenticated MoneyUp archive created explicitly by the user.
        var protectedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(resourceValues)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: directory.path
        )
        #endif

        connection = try SQLCipherConnection(
            databaseURL: databaseURL,
            key: key,
            supportedSchemaVersion: Self.currentSchemaVersion
        )

        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: databaseURL.path
        )
        #endif
    }

    public func upsert<Value: Encodable & Sendable>(
        _ value: Value,
        id: String,
        in collection: RecordCollection
    ) throws {
        try connection.write(
            [try RecordWrite(value, id: id, in: collection)],
            removing: []
        )
    }

    /// Commits all writes and deletions together or rolls every one back.
    public func write(
        _ records: [RecordWrite],
        removing deletions: [RecordDeletion] = [],
        relinkingReceiptAttachments relink: ReceiptAttachmentRelink? = nil
    ) throws {
        try connection.write(
            records,
            removing: deletions,
            relinkingReceiptAttachments: relink
        )
    }

    /// Reads only the compact encrypted SQL index; attachment blobs never
    /// enter process memory on unlock or while rendering transaction lists.
    public func receiptAttachmentIndexSnapshot() throws
        -> ReceiptAttachmentIndexSnapshot {
        try connection.receiptAttachmentIndexSnapshot()
    }

    /// Fetches one selected receipt. Identity and metadata are checked against
    /// the normalized index before bytes can reach the UI.
    public func receiptAttachment(id: UUID) throws -> ReceiptAttachment? {
        try connection.receiptAttachment(id: id)
    }

    /// Resolves compact identities for a journal cascade without decoding any
    /// receipt bytes.
    public func receiptAttachmentIDs(entryID: UUID) throws -> [UUID] {
        try connection.receiptAttachmentIDs(entryID: entryID)
    }

    public func lastReceiptAttachmentReadDiagnostics()
        -> ReceiptAttachmentReadDiagnostics {
        connection.lastReceiptAttachmentReadDiagnostics
    }

    public func budgetAttributionIndexSnapshot() throws
        -> BudgetAttributionIndexSnapshot {
        try connection.budgetAttributionIndexSnapshot()
    }

    /// Historical budget posting rows with attribution overrides applied in
    /// SQL. The query touches only the requested stable-day range and never
    /// decodes attribution or journal JSON blobs.
    public func fetchBudgetPostingEvents(
        originDayKeyRange: Range<Int>,
        excludingEntryIDs: Set<UUID> = []
    ) throws -> [LedgerPostingEvent] {
        guard !originDayKeyRange.isEmpty else { return [] }
        return try makePostingEvents(
            from: connection.fetchBudgetPostings(
                startDayKey: originDayKeyRange.lowerBound,
                endDayKeyExclusive: originDayKeyRange.upperBound
            ),
            excludingEntryIDs: excludingEntryIDs
        )
    }

    public func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        id: String,
        from collection: RecordCollection
    ) throws -> Value? {
        guard let payload = try connection.fetch(
            collection: collection.rawValue,
            recordID: id
        ) else {
            return nil
        }

        do {
            return try Self.makeDecoder().decode(type, from: payload)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
    }

    public func fetchAll<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from collection: RecordCollection
    ) throws -> [Value] {
        try connection.fetchAll(collection: collection.rawValue).map { record in
            do {
                return try Self.makeDecoder().decode(type, from: record.payload)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PersistenceError.invalidStoredRecord(
                    collection: collection,
                    recordID: record.id
                )
            }
        }
    }

    /// Decodes every valid row and reports malformed rows individually.
    /// A single damaged convenience or historical record must not hide the
    /// remainder of an otherwise readable book.
    public func fetchAllRecovering<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from collection: RecordCollection
    ) throws -> RecoveredRecords<Value> {
        var values: [Value] = []
        var issues: [RecordDecodeIssue] = []

        for record in try connection.fetchAll(collection: collection.rawValue) {
            do {
                values.append(try Self.makeDecoder().decode(type, from: record.payload))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(
                    RecordDecodeIssue(collection: collection, recordID: record.id)
                )
            }
        }
        return RecoveredRecords(values: values, issues: issues)
    }

    /// Recovery read for collections whose physical key must be the exact
    /// canonical UUID carried by the payload. A decodable alias is still
    /// quarantined: otherwise a later canonical update/delete can leave the
    /// alias behind and resurrect stale state on the next launch.
    public func fetchAllIdentifiedRecovering<
        Value: Decodable & Sendable & Identifiable
    >(
        _ type: Value.Type,
        from collection: RecordCollection
    ) throws -> RecoveredRecords<Value> where Value.ID == UUID {
        var values: [Value] = []
        var issues: [RecordDecodeIssue] = []

        for (offset, record) in try connection.fetchAll(
            collection: collection.rawValue
        ).enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            do {
                let value = try Self.makeDecoder().decode(
                    type,
                    from: record.payload
                )
                guard value.id.uuidString == record.id else {
                    issues.append(RecordDecodeIssue(
                        collection: collection,
                        recordID: record.id
                    ))
                    continue
                }
                values.append(value)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(RecordDecodeIssue(
                    collection: collection,
                    recordID: record.id
                ))
            }
        }
        return RecoveredRecords(values: values, issues: issues)
    }

    /// Decodes only journal rows referenced by another collection. SQL binds
    /// IDs in bounded batches, so attribution integrity remains proportional
    /// to attribution count without one actor round-trip per row.
    public func fetchJournalEntriesRecovering(
        ids: Set<UUID>
    ) throws -> RecoveredRecords<JournalEntry> {
        try Task.checkCancellation()
        let records = try connection.fetch(
            collection: RecordCollection.journalEntries.rawValue,
            recordIDs: ids.map(\.uuidString)
        )
        var values: [JournalEntry] = []
        var issues: [RecordDecodeIssue] = []
        for (offset, record) in records.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            do {
                let entry = try Self.makeDecoder().decode(
                    JournalEntry.self,
                    from: record.payload
                )
                guard entry.id.uuidString == record.id else {
                    throw PersistenceError.invalidStoredRecord(
                        collection: .journalEntries,
                        recordID: record.id
                    )
                }
                values.append(entry)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(RecordDecodeIssue(
                    collection: .journalEntries,
                    recordID: record.id
                ))
            }
        }
        return RecoveredRecords(values: values, issues: issues)
    }

    /// Reads a bounded chronological slice directly from SQLCipher's date
    /// index. Bounds follow MoneyUp's half-open period convention.
    public func fetchJournalEntryPage(
        startDate: Date? = nil,
        endDateExclusive: Date? = nil,
        startDayKey: Int? = nil,
        endDayKeyExclusive: Int? = nil,
        after cursor: JournalEntryPageCursor? = nil,
        limit: Int = 80
    ) throws -> JournalEntryPage {
        let boundedLimit = min(max(limit, 1), 500)
        let rawPage = try connection.fetchJournalEntryPage(
            startDate: startDate,
            endDateExclusive: endDateExclusive,
            startDayKey: startDayKey,
            endDayKeyExclusive: endDayKeyExclusive,
            after: cursor,
            limit: boundedLimit
        )
        var entries: [JournalEntry] = []
        var issues: [RecordDecodeIssue] = []
        for record in rawPage.records {
            do {
                let entry = try Self.makeDecoder().decode(
                    JournalEntry.self,
                    from: record.payload
                )
                guard entry.id.uuidString == record.id else {
                    throw PersistenceError.invalidStoredRecord(
                        collection: .journalEntries,
                        recordID: record.id
                    )
                }
                entries.append(entry)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(
                    RecordDecodeIssue(
                        collection: .journalEntries,
                        recordID: record.id
                    )
                )
            }
        }
        return JournalEntryPage(
            entries: entries,
            issues: issues,
            nextCursor: rawPage.nextCursor
        )
    }

    /// Reads only normalized posting rows in the requested half-open date
    /// range. This is the reporting/Calendar path and never touches journal
    /// JSON payloads.
    public func fetchJournalPostingEvents(
        startDate: Date,
        endDateExclusive: Date,
        excludingEntryIDs: Set<UUID> = []
    ) throws -> [LedgerPostingEvent] {
        guard startDate < endDateExclusive else { return [] }
        return try makePostingEvents(
            from: connection.fetchJournalPostings(
                startDate: startDate,
                endDateExclusive: endDateExclusive
            ),
            excludingEntryIDs: excludingEntryIDs
        )
    }

    /// Exact stable-day reporting query. Unlike an instant envelope, this
    /// cannot miss or misattribute transactions captured in another zone.
    public func fetchJournalPostingEvents(
        originDayKeyRange: Range<Int>,
        excludingEntryIDs: Set<UUID> = []
    ) throws -> [LedgerPostingEvent] {
        guard !originDayKeyRange.isEmpty else { return [] }
        return try makePostingEvents(
            from: connection.fetchJournalPostings(
                startDayKey: originDayKeyRange.lowerBound,
                endDayKeyExclusive: originDayKeyRange.upperBound
            ),
            excludingEntryIDs: excludingEntryIDs
        )
    }

    private func makePostingEvents(
        from rows: [IndexedPostingRow],
        excludingEntryIDs: Set<UUID>
    ) throws -> [LedgerPostingEvent] {
        let excluded = Set(excludingEntryIDs.map { $0.uuidString.lowercased() })
        return try rows.compactMap { row in
            guard !excluded.contains(row.entryID.lowercased()) else { return nil }
            guard let entryID = UUID(uuidString: row.entryID),
                  let postingID = UUID(uuidString: row.postingID),
                  let accountID = UUID(uuidString: row.accountID),
                  let amount = Decimal(
                    string: row.amount,
                    locale: Locale(identifier: "en_US_POSIX")
                  ) else {
                throw PersistenceError.invalidStoredRecord(
                    collection: .journalEntries,
                    recordID: row.entryID
                )
            }
            let currency: CurrencyCode
            do {
                currency = try CurrencyCode(row.currency)
            } catch {
                throw PersistenceError.invalidStoredRecord(
                    collection: .journalEntries,
                    recordID: row.entryID
                )
            }
            let money: Money
            do {
                money = try Money(amount, currency: currency)
            } catch {
                throw PersistenceError.invalidStoredRecord(
                    collection: .journalEntries,
                    recordID: row.entryID
                )
            }
            return LedgerPostingEvent(
                entryID: entryID,
                occurredAt: Date(timeIntervalSince1970: row.occurredAt),
                originDayKey: row.originDayKey,
                posting: Posting(
                    id: postingID,
                    accountID: accountID,
                    money: money
                )
            )
        }
    }

    /// Loads exact balances and relationship counts from materialized index
    /// rows. Malformed journal JSON has no index row and is reported without
    /// being decoded; entries that point at quarantined accounts are removed
    /// from both balances and counts as one atomic ledger unit.
    public func journalLedgerIndex(
        validAccountIDs: Set<UUID>,
        expectedAccountCurrencies: [UUID: CurrencyCode] = [:]
    ) throws -> JournalLedgerIndexSnapshot {
        let validIDs = Set(validAccountIDs.map(\.uuidString))
        let expectedCurrencies = Dictionary(
            uniqueKeysWithValues: expectedAccountCurrencies.map {
                ($0.key.uuidString, $0.value.value)
            }
        )
        let missingIndexIDs = try connection.fetchUnindexedJournalRecordIDs()
        var invalidEntryStrings = try connection.fetchInvalidJournalEntryIDs(
            validAccountIDs: validIDs,
            expectedAccountCurrencies: expectedCurrencies
        )
        invalidEntryStrings.formUnion(
            try connection.fetchNoncanonicalJournalEntryIDs()
        )
        // A current exact rebuild deliberately leaves a lowercase alias
        // unindexed. If its canonical physical twin is indexed, quarantine
        // that twin too; otherwise balances/history would expose one version
        // of an ambiguous logical transaction while reporting the other as a
        // damaged row.
        let canonicalTwins = missingIndexIDs.compactMap { recordID -> String? in
            guard let id = UUID(uuidString: recordID),
                  id.uuidString != recordID else { return nil }
            return id.uuidString
        }
        invalidEntryStrings.formUnion(
            try connection.fetchExistingJournalEntryIDs(canonicalTwins)
        )
        // Exact Decimal subtraction is needed only for quarantined entries.
        // Healthy books therefore materialize zero historical posting rows.
        let quarantinedPostingRows = try connection.fetchQuarantinedJournalPostings(
            entryIDs: invalidEntryStrings
        )
        let referenceRows = try connection.fetchJournalReferenceCounts(
            validAccountIDs: validIDs
        )

        var decimalBalances: [String: [String: Decimal]] = [:]
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
            decimalBalances[row.accountID.lowercased(), default: [:]][row.currency] = amount
        }

        // A relationship error quarantines the complete entry, including its
        // otherwise valid side of the balanced posting set.
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
            var accountBalances = decimalBalances[accountID] ?? [:]
            accountBalances[row.currency] = try CheckedDecimal.subtracting(
                accountBalances[row.currency] ?? .zero,
                amount
            )
            decimalBalances[accountID] = accountBalances
        }

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

        var invalidReferences: [String: Set<String>] = [:]
        for row in quarantinedPostingRows {
            invalidReferences[row.accountID.lowercased(), default: []]
                // Physical journal identities are binary keys. Preserve
                // their exact spelling so a canonical row and legacy
                // lowercase alias each remove one distinct SQL reference.
                .insert(row.entryID)
        }
        var referenceCounts: [UUID: Int] = [:]
        for row in referenceRows {
            guard let accountID = UUID(uuidString: row.accountID) else { continue }
            referenceCounts[accountID] = max(
                0,
                row.count - invalidReferences[row.accountID.lowercased(), default: []].count
            )
        }

        let invalidRelationshipIDs = Set(
            invalidEntryStrings.compactMap { UUID(uuidString: $0) }
        )
        let issues = missingIndexIDs.map {
            RecordDecodeIssue(collection: .journalEntries, recordID: $0)
        } + invalidEntryStrings.sorted().map {
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
            ) - missingIndexIDs.count - invalidEntryStrings.count,
            balances: balances,
            referenceCounts: referenceCounts,
            issues: issues,
            invalidRelationshipEntryIDs: invalidRelationshipIDs
        )
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

    /// Creates the current portable archive directly from the encrypted SQL
    /// cursor. At most one bounded record and one encryption chunk are resident
    /// at a time; the complete book is never copied into a process array.
    public func exportPortableArchive(
        to destinationURL: URL,
        password: String
    ) throws {
        try connection.exportPortableArchive(
            to: destinationURL,
            password: password
        )
    }

    /// Replaces the complete logical store from an authenticated archive in
    /// one SQLite transaction. Every version-2 record is decoded and indexed
    /// incrementally; any authentication, validation, cancellation, or write
    /// failure rolls the entire candidate back.
    public func restorePortableArchive(
        from sourceURL: URL,
        password: String,
        observesCancellation: Bool = true
    ) throws {
        try connection.replaceAllRecords(
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
    #endif

    public func close() {
        connection.close()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

private final class SQLCipherConnection: @unchecked Sendable {
    private struct StoredPayload {
        let id: String
        let payload: Data
    }

    private struct BalanceKey: Hashable {
        let accountID: String
        let currency: String
    }

    private var database: OpaquePointer?
    #if DEBUG
    private var shouldFailNextRestoreRollbackForTesting = false
    private var shouldFailNextWriteRollbackForTesting = false
    #endif
    private let supportedSchemaVersion: Int32
    private(set) var lastJournalWriteDiagnostics = JournalWriteDiagnostics(
        priorPostingRowsRead: 0,
        compactBalanceRowsRead: 0,
        journalEntriesChanged: 0
    )
    fileprivate var lastJournalLedgerReadDiagnostics = JournalLedgerReadDiagnostics(
        invalidEntryIDsRead: 0,
        quarantinedPostingRowsRead: 0,
        referenceAggregateRowsRead: 0
    )
    fileprivate var lastReceiptAttachmentReadDiagnostics =
        ReceiptAttachmentReadDiagnostics(metadataRowsRead: 0, blobPayloadsDecoded: 0)

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

    private func upsertRecord(
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
        try execute("BEGIN IMMEDIATE;")
        do {
            let metricsBeforeWrite = try storageMetrics()
            let updatedAt = Date().timeIntervalSince1970
            var balanceDeltas: [BalanceKey: Decimal] = [:]
            var priorPostingRowsRead = 0
            var journalEntriesChanged = 0
            for record in records {
                if record.collection == .journalEntries {
                    let prior = try postingTotals(forEntryID: record.id)
                    priorPostingRowsRead += prior.rowCount
                    for (key, amount) in prior.totals {
                        balanceDeltas[key] = try CheckedDecimal.subtracting(
                            balanceDeltas[key] ?? .zero,
                            amount
                        )
                    }
                    journalEntriesChanged += 1
                }
                try upsertRecord(
                    collection: record.collection.rawValue,
                    recordID: record.id,
                    payload: record.payload,
                    updatedAt: updatedAt,
                    indexedAt: record.indexedAt
                )
                if record.collection == .journalEntries {
                    try replaceJournalIndex(
                        entryID: record.id,
                        with: record.journalIndex
                    )
                    for (key, amount) in try postingTotals(
                        for: record.journalIndex
                    ) {
                        balanceDeltas[key] = try CheckedDecimal.adding(
                            balanceDeltas[key] ?? .zero,
                            amount
                        )
                    }
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
            }
            if let relink {
                try relinkReceiptAttachments(
                    from: relink.sourceEntryID,
                    to: relink.destinationEntryID,
                    updatedAt: updatedAt
                )
            }
            for deletion in deletions {
                if deletion.collection == .journalEntries {
                    let prior = try postingTotals(forEntryID: deletion.id)
                    priorPostingRowsRead += prior.rowCount
                    for (key, amount) in prior.totals {
                        balanceDeltas[key] = try CheckedDecimal.subtracting(
                            balanceDeltas[key] ?? .zero,
                            amount
                        )
                    }
                    journalEntriesChanged += 1
                    try deleteJournalIndex(entryID: deletion.id)
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
            }
            let compactBalanceRowsRead = try applyBalanceDeltas(balanceDeltas)
            try enforceLogicalStoreLimits(
                before: metricsBeforeWrite,
                after: storageMetrics()
            )
            try execute("COMMIT;")
            lastJournalWriteDiagnostics = JournalWriteDiagnostics(
                priorPostingRowsRead: priorPostingRowsRead,
                compactBalanceRowsRead: compactBalanceRowsRead,
                journalEntriesChanged: journalEntriesChanged
            )
        } catch let operationError {
            do {
                #if DEBUG
                if shouldFailNextWriteRollbackForTesting {
                    shouldFailNextWriteRollbackForTesting = false
                    try execute(
                        "ROLLBACK TO moneyup_missing_write_savepoint;"
                    )
                }
                #endif
                try execute("ROLLBACK;")
            } catch {
                close()
                throw PersistenceError.transactionStateIndeterminate
            }
            throw operationError
        }
    }

    private func relinkReceiptAttachments(
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
                createdAt: original.createdAt
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

    private func replaceReceiptAttachmentIndex(
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
    }

    private func upsertReceiptAttachmentIndex(
        attachmentID: String,
        index: ReceiptAttachmentIndexWrite
    ) throws {
        try withStatement(
            """
            INSERT INTO receipt_attachment_index (
                attachment_id, entry_id, media_type, byte_count, created_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(attachment_id) DO UPDATE SET
                entry_id = excluded.entry_id,
                media_type = excluded.media_type,
                byte_count = excluded.byte_count,
                created_at = excluded.created_at;
            """
        ) { statement in
            try bindText(attachmentID, at: 1, to: statement)
            try bindText(index.entryID, at: 2, to: statement)
            try bindText(index.mediaType, at: 3, to: statement)
            guard sqlite3_bind_int64(statement, 4, sqlite3_int64(index.byteCount)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 5, index.createdAt) == SQLITE_OK else {
                throw makeError()
            }
            try stepExpectingDone(statement)
        }
    }

    private func deleteReceiptAttachmentIndex(attachmentID: String) throws {
        try withStatement(
            "DELETE FROM receipt_attachment_index WHERE attachment_id = ?;"
        ) { statement in
            try bindText(attachmentID, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
    }

    private func replaceBudgetAttributionIndex(
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

    private func deleteBudgetAttributionIndex(entryID: String) throws {
        try withStatement(
            "DELETE FROM budget_attribution_entry_index WHERE entry_id = ?;"
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
    }

    private func replaceJournalIndex(
        entryID: String,
        with index: JournalIndexWrite?,
        observesCancellation: Bool = true
    ) throws {
        try deleteJournalIndex(entryID: entryID)
        guard let index else { return }
        try withStatement(
            """
            INSERT INTO journal_entry_index (
                entry_id, occurred_at, origin_day_key, source_fingerprint,
                budget_integrity_fingerprint
            ) VALUES (?, ?, ?, ?, ?);
            """
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try bindDouble(index.occurredAt, at: 2, to: statement)
            guard sqlite3_bind_int64(
                statement,
                3,
                Int64(index.originDayKey)
            ) == SQLITE_OK else { throw makeError() }
            try bindOptionalText(index.sourceFingerprint, at: 4, to: statement)
            try bindBlob(
                index.budgetIntegrityFingerprint,
                at: 5,
                to: statement
            )
            try stepExpectingDone(statement)
        }
        for (postingIndex, posting) in index.postings.enumerated() {
            if observesCancellation && postingIndex.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            try withStatement(
                """
                INSERT INTO journal_posting_index (
                    entry_id, posting_id, occurred_at, account_id,
                    currency, amount_text
                ) VALUES (?, ?, ?, ?, ?, ?);
                """
            ) { statement in
                try bindText(entryID, at: 1, to: statement)
                try bindText(posting.postingID, at: 2, to: statement)
                try bindDouble(index.occurredAt, at: 3, to: statement)
                try bindText(posting.accountID, at: 4, to: statement)
                try bindText(posting.currency, at: 5, to: statement)
                try bindText(posting.amount, at: 6, to: statement)
                try stepExpectingDone(statement)
            }
        }
    }

    private func deleteJournalIndex(entryID: String) throws {
        try withStatement(
            "DELETE FROM journal_entry_index WHERE entry_id = ?;"
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            try stepExpectingDone(statement)
        }
    }

    private func postingTotals(
        forEntryID entryID: String
    ) throws -> (totals: [BalanceKey: Decimal], rowCount: Int) {
        try withStatement(
            """
            SELECT account_id, currency, amount_text
            FROM journal_posting_index
            WHERE entry_id = ?;
            """
        ) { statement in
            try bindText(entryID, at: 1, to: statement)
            var result: [BalanceKey: Decimal] = [:]
            var rowCount = 0
            let locale = Locale(identifier: "en_US_POSIX")
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0),
                      let rawCurrency = sqlite3_column_text(statement, 1),
                      let rawAmount = sqlite3_column_text(statement, 2),
                      let amount = Decimal(
                        string: String(cString: rawAmount),
                        locale: locale
                      ) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                let key = BalanceKey(
                    accountID: String(cString: rawAccountID),
                    currency: String(cString: rawCurrency)
                )
                result[key] = try CheckedDecimal.adding(
                    result[key] ?? .zero,
                    amount
                )
                rowCount += 1
            }
            return (result, rowCount)
        }
    }

    private func postingTotals(
        for index: JournalIndexWrite?
    ) throws -> [BalanceKey: Decimal] {
        guard let index else { return [:] }
        let locale = Locale(identifier: "en_US_POSIX")
        var result: [BalanceKey: Decimal] = [:]
        for posting in index.postings {
            guard let amount = Decimal(string: posting.amount, locale: locale) else {
                throw makeError(code: SQLITE_CORRUPT)
            }
            let key = BalanceKey(
                accountID: posting.accountID,
                currency: posting.currency
            )
            result[key] = try CheckedDecimal.adding(
                result[key] ?? .zero,
                amount
            )
        }
        return result
    }

    /// Applies exact posting deltas by reading one compact row per affected
    /// account/currency. This is O(changed postings), never O(journal size).
    private func applyBalanceDeltas(
        _ deltas: [BalanceKey: Decimal]
    ) throws -> Int {
        let locale = Locale(identifier: "en_US_POSIX")
        var rowsRead = 0
        for (key, delta) in deltas where delta != .zero {
            let existing: Decimal? = try withStatement(
                """
                SELECT amount_text FROM journal_balance
                WHERE account_id = ? AND currency = ?;
                """
            ) { statement in
                try bindText(key.accountID, at: 1, to: statement)
                try bindText(key.currency, at: 2, to: statement)
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return nil }
                guard step == SQLITE_ROW,
                      let rawAmount = sqlite3_column_text(statement, 0),
                      let value = Decimal(
                        string: String(cString: rawAmount),
                        locale: locale
                      ) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                rowsRead += 1
                return value
            }
            let updated = try CheckedDecimal.adding(existing ?? .zero, delta)
            if updated == .zero {
                try withStatement(
                    """
                    DELETE FROM journal_balance
                    WHERE account_id = ? AND currency = ?;
                    """
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try stepExpectingDone(statement)
                }
            } else {
                try withStatement(
                    """
                    INSERT INTO journal_balance (account_id, currency, amount_text)
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_id, currency) DO UPDATE SET
                        amount_text = excluded.amount_text;
                    """
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try bindText(
                        NSDecimalNumber(decimal: updated).stringValue,
                        at: 3,
                        to: statement
                    )
                    try stepExpectingDone(statement)
                }
            }
        }
        return rowsRead
    }

    private func rebuildBalances(
        for keys: Set<BalanceKey>,
        observesCancellation: Bool = true
    ) throws {
        guard !keys.isEmpty else { return }
        let locale = Locale(identifier: "en_US_POSIX")
        var totals: [BalanceKey: Decimal] = [:]
        var rowIndex = 0
        try withStatement(
            """
            SELECT account_id, currency, amount_text
            FROM journal_posting_index;
            """
        ) { statement in
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0),
                      let rawCurrency = sqlite3_column_text(statement, 1),
                      let rawAmount = sqlite3_column_text(statement, 2) else {
                    throw makeError(
                        code: step == SQLITE_ROW ? SQLITE_CORRUPT : step
                    )
                }
                if observesCancellation && rowIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                rowIndex += 1
                let key = BalanceKey(
                    accountID: String(cString: rawAccountID),
                    currency: String(cString: rawCurrency)
                )
                guard keys.contains(key) else { continue }
                guard let amount = Decimal(
                    string: String(cString: rawAmount),
                    locale: locale
                ) else {
                    throw makeError(code: SQLITE_CORRUPT)
                }
                totals[key] = try CheckedDecimal.adding(
                    totals[key] ?? .zero,
                    amount
                )
            }
        }

        for (keyIndex, key) in keys.enumerated() {
            if observesCancellation && keyIndex.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if let total = totals[key] {
                try withStatement(
                    """
                    INSERT INTO journal_balance (account_id, currency, amount_text)
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_id, currency) DO UPDATE SET
                        amount_text = excluded.amount_text;
                    """
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try bindText(
                        NSDecimalNumber(decimal: total).stringValue,
                        at: 3,
                        to: statement
                    )
                    try stepExpectingDone(statement)
                }
            } else {
                try withStatement(
                    "DELETE FROM journal_balance WHERE account_id = ? AND currency = ?;"
                ) { statement in
                    try bindText(key.accountID, at: 1, to: statement)
                    try bindText(key.currency, at: 2, to: statement)
                    try stepExpectingDone(statement)
                }
            }
        }
    }

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

    func budgetAttributionIndexSnapshot() throws
        -> BudgetAttributionIndexSnapshot {
        let counts: (Int, Int, Int) = try withStatement(
            """
            SELECT
                (SELECT COUNT(*) FROM records WHERE collection = ?),
                (SELECT COUNT(*) FROM budget_attribution_entry_index),
                (SELECT COUNT(*) FROM budget_attribution_posting_index);
            """
        ) { statement in
            try bindText(
                RecordCollection.budgetEntryAttributions.rawValue,
                at: 1,
                to: statement
            )
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return (
                Int(sqlite3_column_int64(statement, 0)),
                Int(sqlite3_column_int64(statement, 1)),
                Int(sqlite3_column_int64(statement, 2))
            )
        }
        // A mismatch can be a valid audited lifecycle remap or a legacy
        // inferred-day attribution, but either case requires the slower exact
        // domain validator. Healthy histories avoid decoding attribution JSON.
        let requiresDetailedValidation: Bool = try withStatement(
            """
            SELECT EXISTS (
                SELECT 1
                FROM budget_attribution_entry_index AS attribution
                JOIN journal_entry_index AS journal
                    ON journal.entry_id = attribution.entry_id
                WHERE attribution.integrity_fingerprint IS NULL
                    OR journal.budget_integrity_fingerprint IS NULL
                    OR attribution.integrity_fingerprint
                        <> journal.budget_integrity_fingerprint
                    OR attribution.occurred_at <> journal.occurred_at
                    OR attribution.origin_day_key <> journal.origin_day_key

                UNION ALL

                SELECT 1
                FROM budget_attribution_posting_index AS attribution
                LEFT JOIN journal_posting_index AS journal
                    ON journal.entry_id = attribution.entry_id
                    AND journal.posting_id = attribution.posting_id
                WHERE journal.posting_id IS NULL
                    OR attribution.account_id <> journal.account_id
                    OR attribution.currency <> journal.currency
                    OR attribution.amount_text <> journal.amount_text

                UNION ALL

                SELECT 1
                FROM journal_posting_index AS journal
                JOIN budget_attribution_entry_index AS attribution_entry
                    ON attribution_entry.entry_id = journal.entry_id
                LEFT JOIN budget_attribution_posting_index AS attribution
                    ON attribution.entry_id = journal.entry_id
                    AND attribution.posting_id = journal.posting_id
                WHERE attribution.posting_id IS NULL
                LIMIT 1
            );
            """
        ) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return sqlite3_column_int(statement, 0) != 0
        }
        let issueIDs: [String] = try withStatement(
            """
            SELECT records.record_id
            FROM records
            LEFT JOIN budget_attribution_entry_index AS attribution
                ON attribution.entry_id = records.record_id
            WHERE records.collection = ?
                AND (
                    attribution.entry_id IS NULL
                    OR records.record_id <> UPPER(records.record_id)
                )

            UNION

            SELECT attribution.entry_id
            FROM budget_attribution_entry_index AS attribution
            LEFT JOIN journal_entry_index AS journal
                ON journal.entry_id = attribution.entry_id
            WHERE journal.entry_id IS NULL
            ORDER BY 1 ASC;
            """
        ) { statement in
            try bindText(
                RecordCollection.budgetEntryAttributions.rawValue,
                at: 1,
                to: statement
            )
            var ids: [String] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(
                        code: result == SQLITE_ROW ? SQLITE_CORRUPT : result
                    )
                }
                ids.append(String(cString: rawID))
            }
            return ids
        }
        return BudgetAttributionIndexSnapshot(
            recordCount: counts.0,
            indexedEntryCount: counts.1,
            indexedPostingCount: counts.2,
            requiresDetailedValidation: requiresDetailedValidation,
            issues: issueIDs.map {
                RecordDecodeIssue(
                    collection: .budgetEntryAttributions,
                    recordID: $0
                )
            }
        )
    }

    func fetchInvalidJournalEntryIDs(
        validAccountIDs: Set<String>,
        expectedAccountCurrencies: [String: String]
    ) throws -> Set<String> {
        let sortedAccountIDs = validAccountIDs.sorted()
        let predicate: String
        if sortedAccountIDs.isEmpty {
            predicate = "1 = 1"
        } else {
            predicate = "account_id NOT IN (\(Self.placeholders(sortedAccountIDs.count)))"
        }
        var result = try withStatement(
            """
            SELECT DISTINCT entry_id
            FROM journal_posting_index
            WHERE \(predicate)
            ORDER BY entry_id ASC;
            """
        ) { statement in
            for (offset, accountID) in sortedAccountIDs.enumerated() {
                try bindText(accountID, at: Int32(offset + 1), to: statement)
            }
            var result = Set<String>()
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawEntryID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                result.insert(String(cString: rawEntryID))
            }
            return result
        }

        // Account metadata is encrypted generic-record state and therefore is
        // supplied by the actor-isolated caller. Query mismatches in bounded
        // batches so books with many accounts never exceed SQLite's variable
        // limit. A single mismatched posting quarantines its complete entry.
        let sortedCurrencies = expectedAccountCurrencies.sorted {
            if $0.key == $1.key { return $0.value < $1.value }
            return $0.key < $1.key
        }
        for batchStart in stride(from: 0, to: sortedCurrencies.count, by: 200) {
            let batch = Array(
                sortedCurrencies[batchStart..<min(batchStart + 200, sortedCurrencies.count)]
            )
            guard !batch.isEmpty else { continue }
            let predicate = batch.map { _ in
                "(account_id = ? AND currency <> ?)"
            }.joined(separator: " OR ")
            let mismatches = try withStatement(
                """
                SELECT DISTINCT entry_id
                FROM journal_posting_index
                WHERE \(predicate)
                ORDER BY entry_id ASC;
                """
            ) { statement in
                var binding: Int32 = 1
                for (accountID, currency) in batch {
                    try bindText(accountID, at: binding, to: statement)
                    binding += 1
                    try bindText(currency, at: binding, to: statement)
                    binding += 1
                }
                var mismatches = Set<String>()
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW,
                          let rawEntryID = sqlite3_column_text(statement, 0) else {
                        throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                    }
                    mismatches.insert(String(cString: rawEntryID))
                }
                return mismatches
            }
            result.formUnion(mismatches)
        }
        return result
    }

    func fetchQuarantinedJournalPostings(
        entryIDs: Set<String>
    ) throws -> [IndexedPostingRow] {
        let sortedEntryIDs = entryIDs.sorted()
        var rows: [IndexedPostingRow] = []
        for batchStart in stride(from: 0, to: sortedEntryIDs.count, by: 400) {
            let batch = Array(
                sortedEntryIDs[batchStart..<min(batchStart + 400, sortedEntryIDs.count)]
            )
            guard !batch.isEmpty else { continue }
            let fetched = try withStatement(
                """
                SELECT posting.entry_id, posting.occurred_at, entry.origin_day_key,
                    posting.posting_id, posting.account_id, posting.currency,
                    posting.amount_text
                FROM journal_posting_index AS posting
                JOIN journal_entry_index AS entry ON entry.entry_id = posting.entry_id
                WHERE posting.entry_id IN (\(Self.placeholders(batch.count)))
                ORDER BY posting.entry_id ASC, posting.posting_id ASC;
                """
            ) { statement in
                for (offset, entryID) in batch.enumerated() {
                    try bindText(entryID, at: Int32(offset + 1), to: statement)
                }
                return try readPostingRows(from: statement)
            }
            rows.append(contentsOf: fetched)
        }
        return rows
    }

    func fetchJournalReferenceCounts(
        validAccountIDs: Set<String>
    ) throws -> [IndexedReferenceCountRow] {
        let sortedAccountIDs = validAccountIDs.sorted()
        guard !sortedAccountIDs.isEmpty else { return [] }
        return try withStatement(
            """
            SELECT account_id, COUNT(DISTINCT entry_id)
            FROM journal_posting_index
            WHERE account_id IN (\(Self.placeholders(sortedAccountIDs.count)))
            GROUP BY account_id
            ORDER BY account_id ASC;
            """
        ) { statement in
            var binding: Int32 = 1
            for accountID in sortedAccountIDs {
                try bindText(accountID, at: binding, to: statement)
                binding += 1
            }
            var rows: [IndexedReferenceCountRow] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
                }
                rows.append(
                    IndexedReferenceCountRow(
                        accountID: String(cString: rawAccountID),
                        count: Int(sqlite3_column_int64(statement, 1))
                    )
                )
            }
            return rows
        }
    }

    private func readPostingRows(
        from statement: OpaquePointer
    ) throws -> [IndexedPostingRow] {
        var rows: [IndexedPostingRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let rawEntryID = sqlite3_column_text(statement, 0),
                  let rawPostingID = sqlite3_column_text(statement, 3),
                  let rawAccountID = sqlite3_column_text(statement, 4),
                  let rawCurrency = sqlite3_column_text(statement, 5),
                  let rawAmount = sqlite3_column_text(statement, 6) else {
                throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
            }
            rows.append(
                IndexedPostingRow(
                    entryID: String(cString: rawEntryID),
                    occurredAt: sqlite3_column_double(statement, 1),
                    originDayKey: Int(sqlite3_column_int64(statement, 2)),
                    postingID: String(cString: rawPostingID),
                    accountID: String(cString: rawAccountID),
                    currency: String(cString: rawCurrency),
                    amount: String(cString: rawAmount)
                )
            )
        }
        return rows
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    func fetchJournalBalances() throws -> [IndexedBalanceRow] {
        try withStatement(
            """
            SELECT account_id, currency, amount_text
            FROM journal_balance
            ORDER BY account_id ASC, currency ASC;
            """
        ) { statement in
            var rows: [IndexedBalanceRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawAccountID = sqlite3_column_text(statement, 0),
                      let rawCurrency = sqlite3_column_text(statement, 1),
                      let rawAmount = sqlite3_column_text(statement, 2) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                rows.append(
                    IndexedBalanceRow(
                        accountID: String(cString: rawAccountID),
                        currency: String(cString: rawCurrency),
                        amount: String(cString: rawAmount)
                    )
                )
            }
            return rows
        }
    }

    func fetchUnindexedJournalRecordIDs() throws -> [String] {
        try withStatement(
            """
            SELECT records.record_id
            FROM records
            LEFT JOIN journal_entry_index
                ON journal_entry_index.entry_id = records.record_id
            WHERE records.collection = ?
                AND journal_entry_index.entry_id IS NULL
            ORDER BY records.record_id ASC;
            """
        ) { statement in
            try bindText(
                RecordCollection.journalEntries.rawValue,
                at: 1,
                to: statement
            )
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

    /// Returns legacy indexed UUID keys whose spelling is not the exact
    /// canonical `UUID.uuidString`. If a canonical twin also exists, both
    /// physical rows are quarantined so balances and history cannot expose
    /// two logical versions of one transaction.
    func fetchNoncanonicalJournalEntryIDs() throws -> Set<String> {
        let aliases: Set<String> = try withStatement(
            """
            SELECT entry_id
            FROM journal_entry_index
            WHERE entry_id <> UPPER(entry_id)
            ORDER BY entry_id ASC;
            """
        ) { statement in
            var ids = Set<String>()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawID = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                ids.insert(String(cString: rawID))
            }
            return ids
        }
        guard !aliases.isEmpty else { return [] }
        let canonicalCandidates = aliases.compactMap { recordID in
            UUID(uuidString: recordID)?.uuidString
        }
        return aliases.union(
            try fetchExistingJournalEntryIDs(canonicalCandidates)
        )
    }

    func containsJournalEntry(sourceFingerprint: String) throws -> Bool {
        try withStatement(
            """
            SELECT 1
            FROM journal_entry_index
            WHERE source_fingerprint = ?
            LIMIT 1;
            """
        ) { statement in
            try bindText(sourceFingerprint, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return false }
            guard result == SQLITE_ROW else { throw makeError(code: result) }
            return true
        }
    }

    func fetchExistingJournalEntryIDs(_ candidateIDs: [String]) throws -> Set<String> {
        guard !candidateIDs.isEmpty else { return [] }
        var existing = Set<String>()
        // Stay comfortably below SQLite's default host-parameter limit.
        for start in stride(from: 0, to: candidateIDs.count, by: 400) {
            let batch = Array(candidateIDs[start..<min(start + 400, candidateIDs.count)])
            let rows: Set<String> = try withStatement(
                """
                SELECT entry_id
                FROM journal_entry_index
                WHERE entry_id IN (\(Self.placeholders(batch.count)));
                """
            ) { statement in
                for (offset, entryID) in batch.enumerated() {
                    try bindText(entryID, at: Int32(offset + 1), to: statement)
                }
                var result = Set<String>()
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW,
                          let rawEntryID = sqlite3_column_text(statement, 0) else {
                        throw makeError(
                            code: step == SQLITE_ROW ? SQLITE_CORRUPT : step
                        )
                    }
                    result.insert(String(cString: rawEntryID))
                }
                return result
            }
            existing.formUnion(rows)
        }
        return existing
    }

    func fetchJournalSourceFingerprints() throws -> Set<String> {
        try withStatement(
            """
            SELECT DISTINCT source_fingerprint
            FROM journal_entry_index
            WHERE source_fingerprint IS NOT NULL
            ORDER BY source_fingerprint ASC;
            """
        ) { statement in
            var values = Set<String>()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rawValue = sqlite3_column_text(statement, 0) else {
                    throw makeError(code: result == SQLITE_ROW ? SQLITE_CORRUPT : result)
                }
                values.insert(String(cString: rawValue))
            }
            return values
        }
    }

    func journalIndexDiagnostics() throws -> JournalIndexDiagnostics {
        func scalar(_ sql: String) throws -> Int {
            try withStatement(sql) { statement in
                let result = sqlite3_step(statement)
                guard result == SQLITE_ROW else { throw makeError(code: result) }
                return Int(sqlite3_column_int64(statement, 0))
            }
        }
        return try JournalIndexDiagnostics(
            journalRecordCount: count(
                collection: RecordCollection.journalEntries.rawValue
            ),
            indexedEntryCount: scalar("SELECT COUNT(*) FROM journal_entry_index;"),
            indexedPostingCount: scalar("SELECT COUNT(*) FROM journal_posting_index;")
        )
    }

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

    private func receiptAttachmentRecordIDs(entryID: UUID) throws -> [String] {
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

    private func enumerateAllRecords(
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
                try validateReplacementRecord(
                    record,
                    allowedCollections: allowedCollections,
                    identities: &identities
                )
                try insertReplacementRecord(
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

    private func clearRecordsForReplacement() throws {
        try execute("DELETE FROM journal_entry_index;")
        try execute("DELETE FROM journal_balance;")
        try execute("DELETE FROM receipt_attachment_index;")
        try execute("DELETE FROM budget_attribution_entry_index;")
        try execute("DELETE FROM records;")
    }

    private func validateReplacementRecord(
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

    private func insertReplacementRecord(
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

    private func rollbackReplacement(orThrowing operationError: Error) throws {
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

    private func enforceLogicalStoreLimits(
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

    private func verifyCipher() throws {
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

    private func configure() throws {
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

    fileprivate func usesMemoryOnlyTemporaryStorage() throws -> Bool {
        try withStatement("PRAGMA temp_store;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw makeError()
            }
            // SQLite documents 2 as MEMORY (0 is compile-time default, 1 FILE).
            return sqlite3_column_int(statement, 0) == 2
        }
    }

    private func migrateIfNeeded() throws {
        var currentVersion: Int32 = try withStatement("PRAGMA user_version;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw makeError()
            }
            return sqlite3_column_int(statement, 0)
        }

        guard currentVersion <= supportedSchemaVersion else {
            throw PersistenceError.unsupportedSchema(
                found: currentVersion,
                supported: supportedSchemaVersion
            )
        }

        if currentVersion == 0 {
            try execute("BEGIN IMMEDIATE;")
            do {
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
                try execute("COMMIT;")
                currentVersion = 2
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }

        if currentVersion < 2 {
            try execute("BEGIN IMMEDIATE;")
            do {
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
                        try bindText(record.id, at: 3, to: statement)
                        try stepExpectingDone(statement)
                    }
                }
                try execute("PRAGMA user_version = 2;")
                try execute("COMMIT;")
                currentVersion = 2
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }

        if currentVersion < 3 {
            try execute("BEGIN IMMEDIATE;")
            do {
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
                try execute("COMMIT;")
                currentVersion = 3
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }

        if currentVersion < 4 {
            try execute("BEGIN IMMEDIATE;")
            do {
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
                try execute("COMMIT;")
                currentVersion = 4
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }

        if currentVersion < 5 {
            try execute("BEGIN IMMEDIATE;")
            do {
                try createStoreMetricsTable()
                try execute("PRAGMA user_version = 5;")
                try execute("COMMIT;")
                currentVersion = 5
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }

        guard currentVersion < 6 else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            if try !journalEntryIndexHasBudgetIntegrityFingerprint() {
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
            try createBudgetAttributionIndexTables()
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
            for record in try fetchAll(
                collection: RecordCollection.budgetEntryAttributions.rawValue
            ) {
                let index = budgetAttributionIndexWrite(
                    collection: RecordCollection.budgetEntryAttributions.rawValue,
                    recordID: record.id,
                    payload: record.payload
                )
                try replaceBudgetAttributionIndex(
                    entryID: record.id,
                    with: index
                )
            }
            try execute("PRAGMA user_version = 6;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func journalEntryIndexHasBudgetIntegrityFingerprint() throws
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

    private func updateJournalBudgetIntegrityFingerprint(
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
    private func createStoreMetricsTable() throws {
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

    private func recordIDs(collection: String) throws -> [String] {
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

    private func createReceiptAttachmentIndexTable() throws {
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

    private func createBudgetAttributionIndexTables() throws {
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

    private func createJournalIndexTables() throws {
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

    private func journalIndexedAt(
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

    private func journalIndexWrite(
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

    private func receiptAttachmentIndexWrite(
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

    private func budgetAttributionIndexWrite(
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

    private func clearJournalChronologicalIndex(recordID: String) throws {
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

    private func execute(_ sql: String) throws {
        try requireOpen()
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw makeError(code: result)
        }
    }

    private func withStatement<Result>(
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

    private func bindText(
        _ value: String,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else { throw makeError(code: result) }
    }

    private func bindOptionalText(
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

    private func bindBlob(
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

    private func bindDouble(
        _ value: Double,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        guard value.isFinite,
              sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw makeError()
        }
    }

    private func bindOptionalDouble(
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

    private func data(from statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func stepExpectingDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw makeError(code: result) }
    }

    private func requireOpen() throws {
        guard database != nil else { throw PersistenceError.databaseClosed }
    }

    private func makeError(code: Int32? = nil) -> PersistenceError {
        let resolvedCode = code ?? sqlite3_extended_errcode(database)
        let message: String
        if let database, let rawMessage = sqlite3_errmsg(database) {
            message = String(cString: rawMessage)
        } else {
            message = "SQLCipher database error"
        }
        return .databaseFailure(code: resolvedCode, message: message)
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
