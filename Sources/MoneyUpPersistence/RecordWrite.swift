import Foundation

/// A type-erased, already-validated record used for atomic persistence batches.
public struct RecordWrite: Sendable {
    let collection: RecordCollection
    let id: String
    let payload: Data

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
    }

    init(collection: RecordCollection, id: String, payload: Data) {
        self.collection = collection
        self.id = id
        self.payload = payload
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
