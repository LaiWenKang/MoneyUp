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
}
