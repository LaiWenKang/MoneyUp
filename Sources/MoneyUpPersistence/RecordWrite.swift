import CryptoKit
import Foundation
import MoneyUpCore

private struct UUIDRecordIdentity: Decodable {
    let id: UUID
}

private extension RecordCollection {
    var requiresCanonicalPayloadUUID: Bool {
        switch self {
        case .accounts, .journalEntries, .budgetNodes,
             .scheduledTransactions, .investmentHoldings,
             .netWorthSnapshots, .accountLifecycleAudit,
             .receiptAttachments, .exchangeRates, .savingsGoals,
             .loanPlans, .allowancePlans, .budgetEntryAttributions:
            return true
        case .profile, .journalEntryRevisions, .quickLogDrafts,
             .budgetConfigurationTimelines:
            return false
        }
    }
}

struct JournalPostingIndexWrite: Sendable {
    let postingID: String
    let accountID: String
    let currency: String
    let amount: String
    let memo: String?
}

struct JournalIndexWrite: Sendable {
    let recordID: String
    let occurredAt: TimeInterval
    let originDayKey: Int
    let sourceFingerprint: String?
    let normalizedPayeeKey: String?
    let entryKind: String
    let postings: [JournalPostingIndexWrite]
    let budgetIntegrityFingerprint: Data

    init(entry: JournalEntry, recordID: String) {
        self.recordID = recordID
        occurredAt = entry.occurredAt.timeIntervalSince1970
        originDayKey = entry.originContext.dayKey
        sourceFingerprint = entry.sourceFingerprint
        normalizedPayeeKey = PayeeNormalization.boundedIndexKey(entry.payee)
        entryKind = entry.kind.rawValue
        postings = entry.postings.map {
            JournalPostingIndexWrite(
                postingID: $0.id.uuidString,
                accountID: $0.accountID.uuidString,
                currency: $0.money.currency.value,
                amount: NSDecimalNumber(decimal: $0.money.amount).stringValue,
                memo: $0.memo
            )
        }
        budgetIntegrityFingerprint = BudgetAttributionIntegrityFingerprint
            .journal(entry)
    }
}

struct LedgerAccountIndexWrite: Sendable {
    let recordID: String
    let kind: String
    let currency: String?
    let systemRole: String?
    let isArchived: Bool

    init(account: LedgerAccount, recordID: String) {
        self.recordID = recordID
        kind = account.kind.rawValue
        currency = account.currency?.value
        systemRole = account.systemRole?.rawValue
        isArchived = account.isArchived
    }
}

struct ReceiptAttachmentIndexWrite: Sendable {
    let recordID: String
    let entryID: String
    let mediaType: String
    let byteCount: Int
    let createdAt: TimeInterval

    init(attachment: ReceiptAttachment, recordID: String) {
        self.recordID = recordID
        entryID = attachment.entryID.uuidString
        mediaType = attachment.mediaType.rawValue
        byteCount = attachment.data.count
        createdAt = attachment.createdAt.timeIntervalSince1970
    }
}

struct BudgetAttributionIndexWrite: Sendable {
    let recordID: String
    let occurredAt: TimeInterval
    let originDayKey: Int
    let postings: [JournalPostingIndexWrite]
    let integrityFingerprint: Data

    init(attribution: BudgetEntryAttribution, recordID: String) throws {
        let compactDay = attribution.originDayKey.replacingOccurrences(
            of: "-",
            with: ""
        )
        guard let originDayKey = Int(compactDay),
              compactDay.count == 8 else {
            throw PersistenceError.invalidStoredRecord(
                collection: .budgetEntryAttributions,
                recordID: recordID
            )
        }
        self.recordID = recordID
        occurredAt = attribution.occurredAt.timeIntervalSince1970
        self.originDayKey = originDayKey
        postings = attribution.postings.map {
            JournalPostingIndexWrite(
                postingID: $0.id.uuidString,
                accountID: $0.accountID.uuidString,
                currency: $0.money.currency.value,
                amount: NSDecimalNumber(decimal: $0.money.amount).stringValue,
                memo: $0.memo
            )
        }
        integrityFingerprint = BudgetAttributionIntegrityFingerprint
            .attribution(attribution, originDayKey: originDayKey)
    }
}

/// A compact comparison key for the exact fields protected by the startup
/// attribution validator. Account changes and legacy inferred-day differences
/// intentionally produce a mismatch so the audited lifecycle fallback runs.
private enum BudgetAttributionIntegrityFingerprint {
    private static let domain = Data(
        "MoneyUp/BudgetAttributionIntegrity/v1".utf8
    )

    static func journal(_ entry: JournalEntry) -> Data {
        digest(
            kind: entry.originContext.wasInferred
                ? "journal-inferred" : "exact",
            occurredAt: entry.occurredAt,
            originDayKey: entry.originContext.dayKey,
            originTimeZoneIdentifier: entry.originContext.timeZoneIdentifier,
            originUTCOffsetSeconds: entry.originContext.utcOffsetSeconds,
            postings: entry.postings
        )
    }

    static func attribution(
        _ attribution: BudgetEntryAttribution,
        originDayKey: Int
    ) -> Data {
        digest(
            kind: "exact",
            occurredAt: attribution.occurredAt,
            originDayKey: originDayKey,
            originTimeZoneIdentifier: attribution.originTimeZoneIdentifier,
            originUTCOffsetSeconds: attribution.originUTCOffsetSeconds,
            postings: attribution.postings
        )
    }

    private static func digest(
        kind: String,
        occurredAt: Date,
        originDayKey: Int,
        originTimeZoneIdentifier: String,
        originUTCOffsetSeconds: Int,
        postings: [Posting]
    ) -> Data {
        var encoded = domain
        encoded.appendFingerprintString(kind)
        encoded.appendFingerprintInteger(
            occurredAt.timeIntervalSince1970.bitPattern
        )
        encoded.appendFingerprintInteger(Int64(originDayKey))
        encoded.appendFingerprintString(originTimeZoneIdentifier)
        encoded.appendFingerprintInteger(Int64(originUTCOffsetSeconds))
        let orderedPostings = postings.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        encoded.appendFingerprintInteger(UInt64(orderedPostings.count))
        for posting in orderedPostings {
            encoded.appendFingerprintString(posting.id.uuidString)
            encoded.appendFingerprintString(posting.accountID.uuidString)
            encoded.appendFingerprintString(posting.money.currency.value)
            encoded.appendFingerprintString(
                NSDecimalNumber(decimal: posting.money.amount).stringValue
            )
            if let memo = posting.memo {
                encoded.append(1)
                encoded.appendFingerprintString(memo)
            } else {
                encoded.append(0)
            }
        }
        return Data(SHA256.hash(data: encoded))
    }
}

private extension Data {
    mutating func appendFingerprintString(_ value: String) {
        let bytes = Data(value.utf8)
        appendFingerprintInteger(UInt64(bytes.count))
        append(bytes)
    }

    mutating func appendFingerprintInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

/// A type-erased, already-validated record used for atomic persistence batches.
public struct RecordWrite: Sendable {
    public static let maximumRecordIDByteCount = 128
    public static let maximumPayloadByteCount = 1_000_000
    public static let maximumReceiptPayloadByteCount = 24_000_000
    let collection: RecordCollection
    let id: String
    let payload: Data
    /// Optional chronological key used by bounded, cursor-based collection
    /// queries. It is deliberately derived from the validated domain value so
    /// callers cannot let the index disagree with the encrypted payload.
    let indexedAt: TimeInterval?
    /// Normalized, exact ledger projection maintained in the same SQLCipher
    /// transaction as its source JSON record.
    let journalIndex: JournalIndexWrite?
    /// Blob-free receipt projection maintained atomically with the encrypted
    /// payload. Startup and list/export paths read only this compact index.
    let receiptAttachmentIndex: ReceiptAttachmentIndexWrite?
    /// Historical category/day projection used by rollover without decoding
    /// every attribution JSON record during startup.
    let budgetAttributionIndex: BudgetAttributionIndexWrite?
    /// Minimal classification used only by encrypted intelligence queries.
    let ledgerAccountIndex: LedgerAccountIndexWrite?
    /// Present only for the primary profile write. SQLCipher uses it to make
    /// opt-out persistence and derived-index clearing one atomic operation.
    let profileIntelligenceEnabled: Bool?

    public init<Value: Encodable & Sendable>(
        _ value: Value,
        id: String,
        in collection: RecordCollection
    ) throws {
        let payload = try Self.encodedPayload(value)
        try Self.validatePayload(payload, id: id, collection: collection)
        try Self.validateCanonicalIdentity(payload, id: id, collection: collection)
        let journalEntry = try Self.journalEntry(
            payload,
            id: id,
            collection: collection
        )
        let receiptIndex = Self.receiptAttachmentIndex(
            payload,
            id: id,
            collection: collection
        )
        let attributionIndex = try Self.budgetAttributionIndex(
            payload,
            id: id,
            collection: collection
        )
        let accountIndex = try Self.ledgerAccountIndex(
            payload,
            id: id,
            collection: collection
        )
        let intelligenceEnabled = Self.profileIntelligenceEnabled(
            payload,
            id: id,
            collection: collection
        )
        self.collection = collection
        self.id = id
        self.payload = payload
        indexedAt = journalEntry?.occurredAt.timeIntervalSince1970
        journalIndex = journalEntry.map { JournalIndexWrite(entry: $0, recordID: id) }
        receiptAttachmentIndex = receiptIndex
        budgetAttributionIndex = attributionIndex
        ledgerAccountIndex = accountIndex
        profileIntelligenceEnabled = intelligenceEnabled
    }

    private static func encodedPayload<Value: Encodable & Sendable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func validatePayload(
        _ payload: Data,
        id: String,
        collection: RecordCollection
    ) throws {
        let payloadLimit = collection == .receiptAttachments
            ? Self.maximumReceiptPayloadByteCount
            : Self.maximumPayloadByteCount
        guard !id.isEmpty,
              id.utf8.count <= Self.maximumRecordIDByteCount,
              !payload.isEmpty,
              payload.count <= payloadLimit else {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
    }

    private static func validateCanonicalIdentity(
        _ payload: Data,
        id: String,
        collection: RecordCollection
    ) throws {
        guard collection.requiresCanonicalPayloadUUID else { return }
        do {
            let identity = try JSONDecoder().decode(UUIDRecordIdentity.self, from: payload)
            guard identity.id.uuidString == id else {
                throw PersistenceError.invalidStoredRecord(
                    collection: collection,
                    recordID: id
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
    }

    private static func journalEntry(
        _ payload: Data,
        id: String,
        collection: RecordCollection
    ) throws -> JournalEntry? {
        guard collection == .journalEntries else { return nil }
        let entry: JournalEntry
        do {
            entry = try JSONDecoder().decode(JournalEntry.self, from: payload)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
        guard entry.id.uuidString == id else {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
        return entry
    }

    private static func receiptAttachmentIndex(
        _ payload: Data,
        id: String,
        collection: RecordCollection
    ) -> ReceiptAttachmentIndexWrite? {
        guard collection == .receiptAttachments,
              let attachment = try? JSONDecoder().decode(
                  ReceiptAttachment.self,
                  from: payload
              ) else { return nil }
        return attachment.id.uuidString == id
            ? ReceiptAttachmentIndexWrite(attachment: attachment, recordID: id)
            : nil
    }

    private static func budgetAttributionIndex(
        _ payload: Data,
        id: String,
        collection: RecordCollection
    ) throws -> BudgetAttributionIndexWrite? {
        guard collection == .budgetEntryAttributions else { return nil }
        do {
            let attribution = try JSONDecoder().decode(
                BudgetEntryAttribution.self,
                from: payload
            )
            guard attribution.id.uuidString == id else {
                throw PersistenceError.invalidStoredRecord(
                    collection: collection,
                    recordID: id
                )
            }
            return try BudgetAttributionIndexWrite(
                attribution: attribution,
                recordID: id
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
    }

    private static func ledgerAccountIndex(
        _ payload: Data,
        id: String,
        collection: RecordCollection
    ) throws -> LedgerAccountIndexWrite? {
        guard collection == .accounts else { return nil }
        do {
            let account = try JSONDecoder().decode(LedgerAccount.self, from: payload)
            guard account.id.uuidString == id else {
                throw PersistenceError.invalidStoredRecord(
                    collection: collection,
                    recordID: id
                )
            }
            return LedgerAccountIndexWrite(account: account, recordID: id)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
    }

    private static func profileIntelligenceEnabled(
        _ payload: Data,
        id: String,
        collection: RecordCollection
    ) -> Bool? {
        guard collection == .profile,
              id == UserProfile.primaryRecordID else { return nil }
        return (try? JSONDecoder().decode(UserProfile.self, from: payload))?
            .intelligenceEnabled
    }

    init(
        collection: RecordCollection,
        id: String,
        payload: Data,
        indexedAt: TimeInterval? = nil
    ) {
        self.collection = collection
        self.id = id
        self.payload = payload
        if collection == .journalEntries,
           let entry = try? JSONDecoder().decode(JournalEntry.self, from: payload),
           entry.id.uuidString == id {
            self.indexedAt = entry.occurredAt.timeIntervalSince1970
            journalIndex = JournalIndexWrite(entry: entry, recordID: id)
        } else {
            self.indexedAt = collection == .journalEntries ? nil : indexedAt
            journalIndex = nil
        }
        if collection == .receiptAttachments,
           let attachment = try? JSONDecoder().decode(ReceiptAttachment.self, from: payload),
           attachment.id.uuidString == id {
            receiptAttachmentIndex = ReceiptAttachmentIndexWrite(
                attachment: attachment,
                recordID: id
            )
        } else {
            receiptAttachmentIndex = nil
        }
        if collection == .budgetEntryAttributions,
           let attribution = try? JSONDecoder().decode(
               BudgetEntryAttribution.self,
               from: payload
           ),
           attribution.id.uuidString == id {
            budgetAttributionIndex = try? BudgetAttributionIndexWrite(
                attribution: attribution,
                recordID: id
            )
        } else {
            budgetAttributionIndex = nil
        }
        if collection == .accounts,
           let account = try? JSONDecoder().decode(LedgerAccount.self, from: payload),
           account.id.uuidString == id {
            ledgerAccountIndex = LedgerAccountIndexWrite(
                account: account,
                recordID: id
            )
        } else {
            ledgerAccountIndex = nil
        }
        if collection == .profile,
           id == UserProfile.primaryRecordID,
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: payload) {
            profileIntelligenceEnabled = decoded.intelligenceEnabled
        } else {
            profileIntelligenceEnabled = nil
        }
    }
}

/// A deletion that can be committed atomically with one or more record writes.
public struct RecordDeletion: Sendable {
    let collection: RecordCollection
    let id: String

    public init(id: String, from collection: RecordCollection) {
        self.collection = collection
        self.id = id
    }
}

/// Requests an in-transaction receipt ownership rewrite without materializing
/// every image blob in the caller.
public struct ReceiptAttachmentRelink: Sendable {
    let sourceEntryID: UUID
    let destinationEntryID: UUID

    public init(sourceEntryID: UUID, destinationEntryID: UUID) {
        self.sourceEntryID = sourceEntryID
        self.destinationEntryID = destinationEntryID
    }
}
