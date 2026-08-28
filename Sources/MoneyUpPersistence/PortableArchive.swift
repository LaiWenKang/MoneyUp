import CryptoKit
import Foundation

public enum PortableArchiveError: Error, Equatable, Sendable {
    case passwordTooShort
    case passwordTooLong
    case archiveTooLarge
    case invalidArchive
    case unsupportedVersion(Int)
    case authenticationFailed
}

/// Password-protected, authenticated portable backup.
///
/// SQLCipher's live database key is tied to the device passcode. This archive
/// derives an independent AES-256 key from a user-held password so the book can
/// be restored on a replacement device without weakening the live database.
public enum PortableArchive {
    /// Version 2 is a bounded, chunk-authenticated binary stream. Its archive
    /// ceiling is deliberately aligned with the logical-store payload budget,
    /// so every book accepted by current write paths has a complete portable
    /// representation. Version 1 keeps its original compatibility boundary.
    public static let maximumArchiveByteCount = 640_000_000
    public static let maximumLegacyArchiveByteCount = 250_000_000
    public static let maximumNewArchiveByteCount = 640_000_000
    public static let maximumStoredPayloadByteCount = 512_000_000
    public static let maximumPasswordByteCount = 1_024

    private struct Envelope: Codable {
        let version: Int
        let kdf: String
        let iterations: Int
        let salt: Data
        let ciphertext: Data
    }

    static let magic = Data("MONEYUP\u{0}".utf8)
    static let legacyVersion = 1
    static let currentVersion = 2
    /// Version 1 archives use one exact work factor. Accepting attacker-chosen
    /// values would either weaken password derivation or create a CPU denial of
    /// service during restore.
    static let iterationCount = 120_000
    /// Bounds the cancellation latency of the CPU-bound PBKDF without adding
    /// meaningful overhead to its fixed version-1 work factor.
    private static let cancellationCheckIterationInterval = 256
    private static let minimumPasswordLength = 10

    public static func seal(
        _ snapshot: DatabaseSnapshot,
        password: String
    ) throws -> Data {
        try PortableArchiveV2.seal(snapshot, password: password)
    }

    /// Writes the current archive format without materializing the complete
    /// encrypted file in memory. Production backup uses the store-level
    /// streaming API; this snapshot overload remains useful to tests and
    /// migration tools that already own a bounded snapshot.
    public static func seal(
        _ snapshot: DatabaseSnapshot,
        password: String,
        to destinationURL: URL
    ) throws {
        try PortableArchiveV2.seal(
            snapshot,
            password: password,
            to: destinationURL
        )
    }

    /// Retained only for compatibility fixtures. New callers must use the
    /// chunked version-2 writer above.
    static func sealVersionOne(
        _ snapshot: DatabaseSnapshot,
        password: String
    ) throws -> Data {
        try Task.checkCancellation()
        let passwordData = try validatedPasswordData(password)
        try Task.checkCancellation()
        let salt = randomData(count: 16)
        try Task.checkCancellation()
        let payload = try encoder().encode(snapshot)
        try Task.checkCancellation()
        guard payload.count <= maximumLegacyArchiveByteCount else {
            throw PortableArchiveError.archiveTooLarge
        }
        let key = try deriveKey(
            passwordData: passwordData,
            salt: salt,
            iterations: iterationCount
        )
        try Task.checkCancellation()
        let aad = associatedData(
            version: legacyVersion,
            iterations: iterationCount,
            salt: salt
        )
        try Task.checkCancellation()
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: aad)
        try Task.checkCancellation()
        guard let combined = sealed.combined else {
            throw PortableArchiveError.invalidArchive
        }
        let envelope = Envelope(
            version: legacyVersion,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: iterationCount,
            salt: salt,
            ciphertext: combined
        )
        try Task.checkCancellation()
        let archive = magic + (try encoder().encode(envelope))
        try Task.checkCancellation()
        guard archive.count <= maximumLegacyArchiveByteCount else {
            throw PortableArchiveError.archiveTooLarge
        }
        return archive
    }

    public static func open(
        _ data: Data,
        password: String
    ) throws -> DatabaseSnapshot {
        guard data.count > magic.count,
              data.prefix(magic.count) == magic else {
            throw PortableArchiveError.invalidArchive
        }
        let discriminator = data[data.startIndex + magic.count]
        if discriminator == UInt8(currentVersion) {
            return try PortableArchiveV2.open(data, password: password)
        }
        guard discriminator == UInt8(ascii: "{") else {
            throw PortableArchiveError.unsupportedVersion(Int(discriminator))
        }
        return try openVersionOne(data, password: password)
    }

    /// Opens an archive from disk. Version 2 is decrypted and decoded one
    /// bounded chunk/record at a time; version 1 remains memory-mapped for
    /// backward compatibility with already-issued backups.
    public static func open(
        from sourceURL: URL,
        password: String
    ) throws -> DatabaseSnapshot {
        try PortableArchiveV2.open(sourceURL, password: password)
    }

    static func openVersionOne(
        _ data: Data,
        password: String
    ) throws -> DatabaseSnapshot {
        try Task.checkCancellation()
        guard data.count <= maximumLegacyArchiveByteCount else {
            throw PortableArchiveError.archiveTooLarge
        }
        guard data.count > magic.count,
              data.prefix(magic.count) == magic else {
            throw PortableArchiveError.invalidArchive
        }
        try Task.checkCancellation()
        let envelope: Envelope
        do {
            envelope = try decoder().decode(
                Envelope.self,
                from: Data(data.dropFirst(magic.count))
            )
        } catch {
            try Task.checkCancellation()
            throw PortableArchiveError.invalidArchive
        }
        try Task.checkCancellation()
        guard envelope.version == legacyVersion else {
            throw PortableArchiveError.unsupportedVersion(envelope.version)
        }
        guard envelope.kdf == "PBKDF2-HMAC-SHA256",
              envelope.iterations == iterationCount,
              envelope.salt.count == 16,
              envelope.ciphertext.count <= maximumLegacyArchiveByteCount else {
            throw PortableArchiveError.invalidArchive
        }

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
        } catch {
            try Task.checkCancellation()
            throw PortableArchiveError.invalidArchive
        }
        try Task.checkCancellation()

        // Older version-1 writers imposed no maximum and `open` imposed no
        // length policy at all. Preserve every previously derivable key.
        // `derivedKeyData` performs HMAC's equivalent one-time reduction for
        // long keys so PBKDF2 work remains bounded per round.
        let passwordData = legacyVersionOnePasswordData(password)
        try Task.checkCancellation()
        let key = try deriveKey(
            passwordData: passwordData,
            salt: envelope.salt,
            iterations: envelope.iterations
        )
        try Task.checkCancellation()
        let aad = associatedData(
            version: envelope.version,
            iterations: envelope.iterations,
            salt: envelope.salt
        )
        try Task.checkCancellation()
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            try Task.checkCancellation()
            throw PortableArchiveError.authenticationFailed
        }
        try Task.checkCancellation()
        guard plaintext.count <= maximumLegacyArchiveByteCount else {
            throw PortableArchiveError.archiveTooLarge
        }
        let snapshot: DatabaseSnapshot
        do {
            snapshot = try decoder().decode(DatabaseSnapshot.self, from: plaintext)
        } catch {
            try Task.checkCancellation()
            throw PortableArchiveError.invalidArchive
        }
        try Task.checkCancellation()
        return snapshot
    }

    /// RFC 8018 PBKDF2 using HMAC-SHA256. One 32-byte block is sufficient for
    /// AES-256 and keeps portable backup cryptography independently testable.
    static func deriveKey(
        passwordData: Data,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        SymmetricKey(data: try derivedKeyData(
            passwordData: passwordData,
            salt: salt,
            iterations: iterations
        ))
    }

    /// Internal so the persistence test target can verify the implementation
    /// against independent PBKDF2-HMAC-SHA256 vectors. Archive round trips
    /// alone would not detect the same derivation mistake on both code paths.
    static func derivedKeyData(
        password: String,
        salt: Data,
        iterations: Int,
        cancellationProbe: () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws -> Data {
        try cancellationProbe()
        let normalizedPassword = password.precomposedStringWithCanonicalMapping
        try cancellationProbe()
        return try derivedKeyData(
            passwordData: Data(normalizedPassword.utf8),
            salt: salt,
            iterations: iterations,
            cancellationProbe: cancellationProbe
        )
    }

    static func derivedKeyData(
        passwordData: Data,
        salt: Data,
        iterations: Int,
        cancellationProbe: () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws -> Data {
        precondition(iterations > 0)
        try cancellationProbe()
        // SHA-256 HMAC hashes keys longer than its 64-byte block before use.
        // Do that once here instead of asking each PBKDF2 round to process an
        // unbounded legacy password. The resulting HMAC output is identical.
        let boundedPasswordData = passwordData.count > 64
            ? Data(SHA256.hash(data: passwordData))
            : passwordData
        let passwordKey = SymmetricKey(data: boundedPasswordData)
        var blockInput = salt
        blockInput.append(contentsOf: [0, 0, 0, 1])

        var current = Data(HMAC<SHA256>.authenticationCode(
            for: blockInput,
            using: passwordKey
        ))
        var output = current
        if iterations > 1 {
            for iteration in 1..<iterations {
                if iteration.isMultiple(
                    of: cancellationCheckIterationInterval
                ) {
                    try cancellationProbe()
                }
                current = Data(HMAC<SHA256>.authenticationCode(
                    for: current,
                    using: passwordKey
                ))
                for index in output.indices {
                    output[index] ^= current[index]
                }
            }
        }
        try cancellationProbe()
        return output
    }

    /// Normalization precedes both limits so canonically equivalent passwords
    /// have identical acceptance and key bytes. The byte cap bounds every HMAC
    /// operation even when a UI supplies adversarial multi-byte Unicode input.
    static func validatedPasswordData(_ password: String) throws -> Data {
        let (normalizedPassword, passwordData) = normalizedPassword(password)
        guard passwordData.count <= maximumPasswordByteCount else {
            throw PortableArchiveError.passwordTooLong
        }
        guard normalizedPassword.count >= minimumPasswordLength else {
            throw PortableArchiveError.passwordTooShort
        }
        return passwordData
    }

    static func legacyVersionOnePasswordData(
        _ password: String
    ) -> Data {
        normalizedPassword(password).1
    }

    static func normalizedPassword(
        _ password: String
    ) -> (String, Data) {
        let normalized = password.precomposedStringWithCanonicalMapping
        return (normalized, Data(normalized.utf8))
    }

    private static func associatedData(
        version: Int,
        iterations: Int,
        salt: Data
    ) -> Data {
        var data = magic
        data.append(Data("v=\(version);kdf=PBKDF2-HMAC-SHA256;i=\(iterations);".utf8))
        data.append(salt)
        return data
    }

    static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    /// Shared by the app's bounded file reader and persistence tests so backup
    /// and restore cannot silently drift to different aggregate limits.
    public static func isWithinArchiveByteLimit(_ byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maximumArchiveByteCount
    }

    public static func isWithinNewArchiveByteLimit(_ byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maximumNewArchiveByteCount
    }
}
