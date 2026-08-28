import CryptoKit
import Foundation

public enum PortableArchiveError: Error, Equatable, Sendable {
    case passwordTooShort
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
    public static let maximumArchiveByteCount = 250_000_000

    private struct Envelope: Codable {
        let version: Int
        let kdf: String
        let iterations: Int
        let salt: Data
        let ciphertext: Data
    }

    private static let magic = Data("MONEYUP\u{0}".utf8)
    private static let currentVersion = 1
    private static let iterations = 120_000
    private static let minimumPasswordLength = 10

    public static func seal(
        _ snapshot: DatabaseSnapshot,
        password: String
    ) throws -> Data {
        guard password.count >= minimumPasswordLength else {
            throw PortableArchiveError.passwordTooShort
        }
        let salt = randomData(count: 16)
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        let payload = try encoder().encode(snapshot)
        let aad = associatedData(
            version: currentVersion,
            iterations: iterations,
            salt: salt
        )
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw PortableArchiveError.invalidArchive
        }
        let envelope = Envelope(
            version: currentVersion,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: iterations,
            salt: salt,
            ciphertext: combined
        )
        let archive = magic + (try encoder().encode(envelope))
        guard isWithinArchiveByteLimit(archive.count) else {
            throw PortableArchiveError.archiveTooLarge
        }
        return archive
    }

    public static func open(
        _ data: Data,
        password: String
    ) throws -> DatabaseSnapshot {
        guard isWithinArchiveByteLimit(data.count) else {
            throw PortableArchiveError.archiveTooLarge
        }
        guard data.count > magic.count,
              data.prefix(magic.count) == magic else {
            throw PortableArchiveError.invalidArchive
        }
        let envelope: Envelope
        do {
            envelope = try decoder().decode(
                Envelope.self,
                from: Data(data.dropFirst(magic.count))
            )
        } catch {
            throw PortableArchiveError.invalidArchive
        }
        guard envelope.version == currentVersion else {
            throw PortableArchiveError.unsupportedVersion(envelope.version)
        }
        guard envelope.kdf == "PBKDF2-HMAC-SHA256",
              (10_000...1_000_000).contains(envelope.iterations),
              envelope.salt.count == 16 else {
            throw PortableArchiveError.invalidArchive
        }

        let key = deriveKey(
            password: password,
            salt: envelope.salt,
            iterations: envelope.iterations
        )
        let aad = associatedData(
            version: envelope.version,
            iterations: envelope.iterations,
            salt: envelope.salt
        )
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
            return try decoder().decode(DatabaseSnapshot.self, from: plaintext)
        } catch {
            throw PortableArchiveError.authenticationFailed
        }
    }

    /// RFC 8018 PBKDF2 using HMAC-SHA256. One 32-byte block is sufficient for
    /// AES-256 and keeps portable backup cryptography independently testable.
    private static func deriveKey(
        password: String,
        salt: Data,
        iterations: Int
    ) -> SymmetricKey {
        SymmetricKey(data: derivedKeyData(
            password: password,
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
        iterations: Int
    ) -> Data {
        precondition(iterations > 0)
        // Treat canonically equivalent user-visible passwords identically.
        // This matters when a password is entered with a different keyboard or
        // restored on another device that emits decomposed Unicode scalars.
        let normalizedPassword = password.precomposedStringWithCanonicalMapping
        let passwordKey = SymmetricKey(data: Data(normalizedPassword.utf8))
        var blockInput = salt
        blockInput.append(contentsOf: [0, 0, 0, 1])

        var current = Data(HMAC<SHA256>.authenticationCode(
            for: blockInput,
            using: passwordKey
        ))
        var output = current
        if iterations > 1 {
            for _ in 1..<iterations {
                current = Data(HMAC<SHA256>.authenticationCode(
                    for: current,
                    using: passwordKey
                ))
                for index in output.indices {
                    output[index] ^= current[index]
                }
            }
        }
        return output
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

    private static func randomData(count: Int) -> Data {
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
}
