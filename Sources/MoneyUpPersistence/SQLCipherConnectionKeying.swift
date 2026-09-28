import Foundation
import MoneyUpCore
import SQLCipher

/// How MoneyUp hands its key to SQLCipher.
///
/// The device-bound key is 32 random bytes. Handed over as-is, SQLCipher treats
/// it as a passphrase and stretches it with PBKDF2-HMAC-SHA512 at 256,000 rounds
/// on every open: a noticeable part of each unlock, and no added protection for
/// a key that is already uniformly random. From 0.7.3 books are keyed with
/// SQLCipher's raw-key form, `x'<64 hex digits>'`, which uses the bytes directly.
/// The encryption itself (AES-256 pages, HMAC-SHA512 per page) is unchanged.
///
/// A book written by an earlier build was keyed as a passphrase. It still opens,
/// and is then moved to the raw key by copying it, never by changing it in place
/// (`moveLegacyBookToRawKey`).
extension SQLCipherConnection {
    enum KeyForm: Sendable {
        case raw
        case passphrase
    }

    enum LegacyKeyMove: Sendable, Equatable {
        /// Move a passphrase-keyed book to the raw key once it has opened.
        case perform
        /// Open a passphrase-keyed book as it is, as builds before 0.7.3 did.
        case skip
        #if DEBUG
        /// Tests: the move fails after its copy is written, before the swap.
        case failAfterCopyForTesting
        #endif
    }

    /// What a raw-keyed copy must match before it may replace the book.
    struct KeyMoveFingerprint: Equatable {
        var schemaVersion: Int32
        /// Every schema object other than SQLite's own, with its SQL.
        var objects: [String]
        var rowCounts: [String: Int64]
    }

    /// A failed move is retried after this long, so a lasting cause (such as a
    /// nearly full disk) can never make every unlock slower than before.
    static let legacyKeyMoveRetryInterval: TimeInterval = 24 * 60 * 60

    func openDatabase(at databaseURL: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard openResult == SQLITE_OK else {
            throw makeError(code: openResult)
        }
        sqlite3_extended_result_codes(database, 1)
    }

    /// Opens and keys the book: with the raw key first, as every book is keyed
    /// from 0.7.3; otherwise as a passphrase-keyed book from an earlier build,
    /// which is then moved to the raw key. A wrong key fails both ways and
    /// throws exactly as before.
    func openKeyedDatabase(at databaseURL: URL, key: Data, legacyKeyMove: LegacyKeyMove) throws {
        try openDatabase(at: databaseURL)
        try applyKey(key, as: .raw)
        do {
            try verifyCipher()
            return
        } catch let error as PersistenceError where error.isNotADatabase {
            close()
        }
        try openLegacyDatabase(at: databaseURL, key: key)
        guard legacyKeyMove != .skip, Self.legacyKeyMoveIsDue(for: databaseURL) else { return }
        if moveLegacyBookToRawKey(at: databaseURL, key: key, legacyKeyMove: legacyKeyMove) {
            try openDatabase(at: databaseURL)
            try applyKey(key, as: .raw)
            try verifyCipher()
        } else if !isCleanAfterFailedKeyMove {
            close()
            try openLegacyDatabase(at: databaseURL, key: key)
        }
    }

    func applyKey(_ key: Data, as form: KeyForm) throws {
        let result: Int32
        switch form {
        case .passphrase:
            result = key.withUnsafeBytes { bytes in
                sqlite3_key(database, bytes.baseAddress, Int32(bytes.count))
            }
        case .raw:
            var literal = Self.rawKeyLiteral(key)
            defer { literal.resetBytes(in: 0..<literal.count) }
            result = literal.withUnsafeBytes { bytes in
                sqlite3_key(database, bytes.baseAddress, Int32(bytes.count))
            }
        }
        guard result == SQLITE_OK else { throw makeError(code: result) }
    }

    /// The part of `configure()` that key work needs: keys and pages are wiped
    /// from memory, and temporary data never reaches a plaintext file.
    func configureForKeyWork() throws {
        try execute("PRAGMA cipher_memory_security = ON;")
        try execute("PRAGMA temp_store = MEMORY;")
        guard try usesMemoryOnlyTemporaryStorage() else {
            throw PersistenceError.databaseFailure(
                code: SQLITE_MISUSE,
                message: "SQLCipher refused memory-only temporary storage"
            )
        }
    }

    private func openLegacyDatabase(at databaseURL: URL, key: Data) throws {
        try openDatabase(at: databaseURL)
        try applyKey(key, as: .passphrase)
        try verifyCipher()
    }

    /// Moves this open, passphrase-keyed book to the raw key and reports whether
    /// the file at `databaseURL` is now raw-keyed. On success this connection is
    /// closed; on failure it is closed or left a plain legacy connection.
    ///
    /// Until the final rename the book is only read, so a crash at any point
    /// leaves either the untouched book or the complete, checked copy:
    /// 1. The write-ahead log is folded into the book and switched off. That
    ///    needs the only handle on the book, which proves nothing else has it
    ///    open, and no log written under the old key can outlive the move.
    /// 2. One exclusive transaction copies everything into a new file keyed
    ///    with the raw key.
    /// 3. The copy is read back from disk through the raw key and must match
    ///    the book: every schema object, every table's row count, the schema
    ///    version, and a clean quick check.
    /// 4. The copy is flushed to storage, then renamed over the book in one
    ///    atomic step.
    func moveLegacyBookToRawKey(
        at databaseURL: URL,
        key: Data,
        legacyKeyMove: LegacyKeyMove
    ) -> Bool {
        let copyURL = Self.legacyKeyMoveURL(for: databaseURL)
        Self.removeDatabaseFiles(at: copyURL)
        do {
            try configureForKeyWork()
            guard try textPragma("PRAGMA main.journal_mode = DELETE;") == "delete" else {
                throw PersistenceError.databaseFailure(code: SQLITE_BUSY, message: "The book is open elsewhere")
            }
            let expected = try copyBook(toRawKeyed: copyURL, key: key)
            #if DEBUG
            if legacyKeyMove == .failAfterCopyForTesting {
                throw PersistenceError.databaseFailure(code: SQLITE_ABORT, message: "Injected key move failure")
            }
            #endif
            try Self.verifyRawKeyedCopy(at: copyURL, key: key, matches: expected)
            try Self.flushToStorage(copyURL)
            close()
            guard !FileManager.default.fileExists(atPath: databaseURL.path + "-wal"),
                  !FileManager.default.fileExists(atPath: databaseURL.path + "-journal") else {
                throw PersistenceError.databaseFailure(code: SQLITE_BUSY, message: "The book has a journal")
            }
            guard rename(copyURL.path, databaseURL.path) == 0 else {
                throw PersistenceError.databaseFailure(code: SQLITE_IOERR, message: "The copy could not replace the book")
            }
            try? Self.flushToStorage(databaseURL.deletingLastPathComponent())
            Self.removeDatabaseFiles(at: copyURL)
            try? FileManager.default.removeItem(at: Self.legacyKeyMoveDeferralURL(for: databaseURL))
            return true
        } catch {
            Self.removeDatabaseFiles(at: copyURL)
            FileManager.default.createFile(atPath: Self.legacyKeyMoveDeferralURL(for: databaseURL).path, contents: Data())
            return false
        }
    }

    /// Copies the whole book into a new raw-keyed file inside one exclusive
    /// transaction, and returns what the copy must match.
    private func copyBook(toRawKeyed copyURL: URL, key: Data) throws -> KeyMoveFingerprint {
        var literal = Self.rawKeyLiteral(key)
        defer { literal.resetBytes(in: 0..<literal.count) }
        try withStatement("ATTACH DATABASE ? AS raw_keyed KEY ?;") { statement in
            try bindText(copyURL.path, at: 1, to: statement)
            try bindBlob(literal, at: 2, to: statement)
            try stepExpectingDone(statement)
        }
        do {
            try execute("BEGIN EXCLUSIVE;")
            let expected = try keyMoveFingerprint(schema: "main")
            try execute("SELECT sqlcipher_export('raw_keyed');")
            try execute("PRAGMA raw_keyed.user_version = \(expected.schemaVersion);")
            try execute("COMMIT;")
            try execute("DETACH DATABASE raw_keyed;")
            return expected
        } catch {
            if sqlite3_get_autocommit(database) == 0 { try? execute("ROLLBACK;") }
            try? execute("DETACH DATABASE raw_keyed;")
            throw error
        }
    }

    /// No transaction is left open and nothing is still attached, so after a
    /// failed move `configure()` can take this connection back to normal use.
    private var isCleanAfterFailedKeyMove: Bool {
        guard database != nil, sqlite3_get_autocommit(database) != 0 else { return false }
        let attached = try? withStatement("PRAGMA database_list;") { statement -> Bool in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1), String(cString: name) == "raw_keyed" {
                    return true
                }
            }
            return false
        }
        return attached == false
    }

    private static func verifyRawKeyedCopy(
        at copyURL: URL,
        key: Data,
        matches expected: KeyMoveFingerprint
    ) throws {
        let copy = try SQLCipherConnection(openingUnconfigured: copyURL, key: key, as: .raw)
        defer { copy.close() }
        guard try copy.textPragma("PRAGMA quick_check;") == "ok",
              try copy.keyMoveFingerprint(schema: "main") == expected else {
            throw PersistenceError.databaseFailure(
                code: SQLITE_CORRUPT,
                message: "The raw-keyed copy does not match the book"
            )
        }
    }

    func keyMoveFingerprint(schema: String) throws -> KeyMoveFingerprint {
        let schemaVersion = try withStatement("PRAGMA \(schema).user_version;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw makeError() }
            return sqlite3_column_int(statement, 0)
        }
        var objects: [String] = []
        var tables: [String] = []
        try withStatement(
            """
            SELECT type, name, tbl_name, coalesce(sql, '') FROM \(schema).sqlite_master
            WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type, name;
            """
        ) { statement in
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                let fields = (0..<Int32(4)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                }
                objects.append(fields.joined(separator: "\u{1F}"))
                if fields[0] == "table" { tables.append(fields[1]) }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw makeError(code: step) }
        }
        var rowCounts: [String: Int64] = [:]
        for table in tables {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            rowCounts[table] = try withStatement("SELECT count(*) FROM \(schema).\(quoted);") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw makeError() }
                return sqlite3_column_int64(statement, 0)
            }
        }
        return KeyMoveFingerprint(schemaVersion: schemaVersion, objects: objects, rowCounts: rowCounts)
    }

    func textPragma(_ sql: String) throws -> String? {
        try withStatement(sql) { statement -> String? in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    static func legacyKeyMoveURL(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + ".rawkey-move")
    }

    static func legacyKeyMoveDeferralURL(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + ".rawkey-move-deferred")
    }

    static func legacyKeyMoveIsDue(for databaseURL: URL, now: Date = Date()) -> Bool {
        let marker = legacyKeyMoveDeferralURL(for: databaseURL)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              let deferredAt = attributes[.modificationDate] as? Date else { return true }
        // A clock set backwards must not postpone the move indefinitely.
        let elapsed = now.timeIntervalSince(deferredAt)
        return elapsed >= legacyKeyMoveRetryInterval || elapsed < 0
    }

    static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Forces a file or directory through the drive's own cache.
    static func flushToStorage(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw PersistenceError.databaseFailure(code: SQLITE_IOERR, message: "Could not open for flushing")
        }
        defer { _ = Darwin.close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw PersistenceError.databaseFailure(code: SQLITE_IOERR, message: "Could not flush to storage")
        }
    }

    /// `x'<64 uppercase hex digits>'`, the form SQLCipher reads as the key's
    /// bytes. Callers zero the returned bytes after use.
    static func rawKeyLiteral(_ key: Data) -> Data {
        let digits = Array("0123456789ABCDEF".utf8)
        var literal = Data(capacity: key.count * 2 + 3)
        literal.append(contentsOf: Array("x'".utf8))
        for byte in key {
            literal.append(digits[Int(byte >> 4)])
            literal.append(digits[Int(byte & 0x0f)])
        }
        literal.append(UInt8(ascii: "'"))
        return literal
    }

    #if DEBUG
    /// Which key form opens the book at `url`, or nil when neither does.
    static func keyFormForTesting(at url: URL, key: Data) -> KeyForm? {
        for form in [KeyForm.raw, .passphrase] {
            if let handle = try? SQLCipherConnection(openingUnconfigured: url, key: key, as: form) {
                handle.close()
                return form
            }
        }
        return nil
    }

    /// Rewrites the raw-keyed book at `url` as every build before 0.7.3 kept it:
    /// the key used as a passphrase, in write-ahead-log mode.
    static func rewriteAsLegacyBookForTesting(at url: URL, key: Data) throws {
        let legacyURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".legacy-fixture")
        removeDatabaseFiles(at: legacyURL)
        let book = try SQLCipherConnection(openingUnconfigured: url, key: key, as: .raw)
        let schemaVersion = try book.keyMoveFingerprint(schema: "main").schemaVersion
        try book.withStatement("ATTACH DATABASE ? AS legacy KEY ?;") { statement in
            try book.bindText(legacyURL.path, at: 1, to: statement)
            // The key's own 32 bytes, which SQLCipher stretches as a passphrase.
            try book.bindBlob(key, at: 2, to: statement)
            try book.stepExpectingDone(statement)
        }
        try book.execute("SELECT sqlcipher_export('legacy');")
        try book.execute("PRAGMA legacy.user_version = \(schemaVersion);")
        _ = try book.textPragma("PRAGMA legacy.journal_mode = WAL;")
        try book.execute("DETACH DATABASE legacy;")
        book.close()
        removeDatabaseFiles(at: url)
        guard rename(legacyURL.path, url.path) == 0 else {
            throw PersistenceError.databaseFailure(code: SQLITE_IOERR, message: "Could not install the legacy book")
        }
    }
    #endif
}

extension PersistenceError {
    /// SQLCipher reports a key that does not match the file as "not a database".
    var isNotADatabase: Bool {
        guard case let .databaseFailure(code, _) = self else { return false }
        return code & 0xff == SQLITE_NOTADB
    }
}
