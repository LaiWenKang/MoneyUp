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
             .budgetEntryAttributions:
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
}

struct JournalIndexWrite: Sendable {
    let recordID: String
    let occurredAt: TimeInterval
    let originDayKey: Int
    let sourceFingerprint: String?
    let postings: [JournalPostingIndexWrite]

    init(entry: JournalEntry, recordID: String) {
        self.recordID = recordID
        occurredAt = entry.occurredAt.timeIntervalSince1970
        originDayKey = entry.originContext.dayKey
        sourceFingerprint = entry.sourceFingerprint
        postings = entry.postings.map {
            JournalPostingIndexWrite(
                postingID: $0.id.uuidString,
                accountID: $0.accountID.uuidString,
                currency: $0.money.currency.value,
                amount: NSDecimalNumber(decimal: $0.money.amount).stringValue
            )
        }
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

    public init<Value: Encodable & Sendable>(
        _ value: Value,
        id: String,
        in collection: RecordCollection
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.collection = collection
        self.id = id
        payload = try encoder.encode(value)
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
        if collection.requiresCanonicalPayloadUUID {
            do {
                let identity = try JSONDecoder().decode(
                    UUIDRecordIdentity.self,
                    from: payload
                )
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
        let decodedJournalEntry: JournalEntry?
        if collection == .journalEntries {
            do {
                decodedJournalEntry = try JSONDecoder().decode(
                    JournalEntry.self,
                    from: payload
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PersistenceError.invalidStoredRecord(
                    collection: collection,
                    recordID: id
                )
            }
        } else {
            decodedJournalEntry = nil
        }
        if let decodedJournalEntry,
           decodedJournalEntry.id.uuidString != id {
            throw PersistenceError.invalidStoredRecord(
                collection: collection,
                recordID: id
            )
        }
        let journalEntry = decodedJournalEntry
        indexedAt = journalEntry?.occurredAt.timeIntervalSince1970
        journalIndex = journalEntry.map { JournalIndexWrite(entry: $0, recordID: id) }
        let decodedReceiptAttachment: ReceiptAttachment?
        if collection == .receiptAttachments {
            decodedReceiptAttachment = try? JSONDecoder().decode(
                ReceiptAttachment.self,
                from: payload
            )
        } else {
            decodedReceiptAttachment = nil
        }
        receiptAttachmentIndex = decodedReceiptAttachment.flatMap { attachment in
            attachment.id.uuidString == id
                ? ReceiptAttachmentIndexWrite(attachment: attachment, recordID: id)
                : nil
        }
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
