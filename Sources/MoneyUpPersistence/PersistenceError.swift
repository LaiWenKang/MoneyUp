import Foundation

public enum PersistenceError: Error, Equatable, Sendable {
    case invalidKeyLength
    case databaseClosed
    case databaseFailure(code: Int32, message: String)
    case cipherUnavailable
    case unsupportedSchema(found: Int32, supported: Int32)
    case invalidStoredRecord(collection: RecordCollection, recordID: String)
    case invalidSnapshot
    case duplicateSnapshotRecord(collection: String, recordID: String)
    /// A normal write failed and SQLite could not confirm its rollback. The
    /// connection is closed immediately, forcing a clean reopen before more
    /// work can observe or mutate state.
    case transactionStateIndeterminate
    /// Candidate replacement failed and SQLite could not confirm a rollback.
    /// Previously decoded values are stale until an authoritative snapshot is
    /// restored or the connection is closed.
    case restoreTransactionStateIndeterminate
}
