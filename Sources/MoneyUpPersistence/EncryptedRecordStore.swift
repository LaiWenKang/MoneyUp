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

struct IndexedPayloadRecord {
    let id: String
    let payload: Data
    let indexedAt: TimeInterval
}

struct IndexedPayloadPage {
    let records: [IndexedPayloadRecord]
    let nextCursor: JournalEntryPageCursor?
}

struct IndexedPostingRow {
    let entryID: String
    let occurredAt: TimeInterval
    let originDayKey: Int
    let postingID: String
    let accountID: String
    let currency: String
    let amount: String
}

struct IndexedBalanceRow {
    let accountID: String
    let currency: String
    let amount: String
}

struct IndexedReferenceCountRow {
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
        try Task.checkCancellation()
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
        for (offset, record) in rawPage.records.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
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
        try Task.checkCancellation()
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
