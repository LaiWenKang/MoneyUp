import Foundation
import SQLCipher

/// An actor-isolated SQLCipher record store.
///
/// Each record is encoded independently as validated JSON and stored inside an
/// encrypted SQLite database. Journal entries therefore remain atomic, while
/// migrations can evolve collections without rewriting an entire user book.
public actor EncryptedRecordStore {
    public static let currentSchemaVersion: Int32 = 1

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
        let payload = try Self.makeEncoder().encode(value)
        try connection.upsert(
            collection: collection.rawValue,
            recordID: id,
            payload: payload,
            updatedAt: Date().timeIntervalSince1970
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
            } catch {
                throw PersistenceError.invalidStoredRecord(
                    collection: collection,
                    recordID: record.id
                )
            }
        }
    }

    public func remove(id: String, from collection: RecordCollection) throws {
        try connection.remove(collection: collection.rawValue, recordID: id)
    }

    public func removeAll(from collection: RecordCollection) throws {
        try connection.removeAll(collection: collection.rawValue)
    }

    public func count(in collection: RecordCollection) throws -> Int {
        try connection.count(collection: collection.rawValue)
    }

    public func close() {
        connection.close()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private final class SQLCipherConnection: @unchecked Sendable {
    private struct StoredPayload {
        let id: String
        let payload: Data
    }

    private var database: OpaquePointer?
    private let supportedSchemaVersion: Int32

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

    func upsert(
        collection: String,
        recordID: String,
        payload: Data,
        updatedAt: TimeInterval
    ) throws {
        try withStatement(
            """
            INSERT INTO records (collection, record_id, payload, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(collection, record_id) DO UPDATE SET
                payload = excluded.payload,
                updated_at = excluded.updated_at;
            """
        ) { statement in
            try bindText(collection, at: 1, to: statement)
            try bindText(recordID, at: 2, to: statement)
            try bindBlob(payload, at: 3, to: statement)
            guard sqlite3_bind_double(statement, 4, updatedAt) == SQLITE_OK else {
                throw makeError()
            }
            try stepExpectingDone(statement)
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
        try withStatement("DELETE FROM records WHERE collection = ?;") { statement in
            try bindText(collection, at: 1, to: statement)
            try stepExpectingDone(statement)
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
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = FULL;")
        try execute("PRAGMA secure_delete = ON;")
    }

    private func migrateIfNeeded() throws {
        let currentVersion: Int32 = try withStatement("PRAGMA user_version;") { statement in
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

        guard currentVersion < 1 else { return }

        try execute("BEGIN IMMEDIATE;")
        do {
            try execute(
                """
                CREATE TABLE records (
                    collection TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    payload BLOB NOT NULL CHECK(length(payload) > 0),
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (collection, record_id)
                ) WITHOUT ROWID;
                """
            )
            try execute(
                "CREATE INDEX records_updated_at ON records(collection, updated_at);"
            )
            try execute("PRAGMA user_version = 1;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
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
