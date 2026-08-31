import Foundation
import LocalAuthentication
import Security

enum DatabaseKeyStoreError: Error, Equatable, Sendable {
    case authenticationCancelled
    case devicePasscodeRequired
    case unexpectedStatus(OSStatus)
    case invalidStoredKey
}

/// A pure, fail-closed decision boundary for first-install key creation.
///
/// SQLCipher may leave the main file, write-ahead log, or shared-memory file
/// behind independently after an interruption. Any one of them is evidence of
/// an existing encrypted book. Creating a replacement key in that state would
/// make recovery impossible while presenting the failure as a fresh install.
enum DatabaseKeyCreationPolicy {
    static func mayCreateKey(
        databaseExists: Bool,
        writeAheadLogExists: Bool,
        sharedMemoryExists: Bool
    ) -> Bool {
        !databaseExists && !writeAheadLogExists && !sharedMemoryExists
    }

    static func artifactURLs(for databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
    }
}

/// A device-only, non-sensitive tombstone that makes an explicit erase request
/// crash-consistent across the independently keyed SQLCipher book and locked
/// capture inbox. Startup must resolve this marker before reading either data
/// key. The marker is removed only after both keys and every owned ciphertext
/// artifact have been removed.
enum DataEraseIntentStore {
    private static let service = "com.laiwenkang.MoneyUp.data-erase-intent"
    private static let account = "primary"

    static func isPending() throws -> Bool {
        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw DatabaseKeyStoreError.unexpectedStatus(status)
        }
    }

    static func markPending() throws {
        var query = baseQuery
        query[kSecValueData as String] = Data([1])
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw DatabaseKeyStoreError.unexpectedStatus(status)
        }
    }

    static func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DatabaseKeyStoreError.unexpectedStatus(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

extension DatabaseKeyStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .authenticationCancelled:
            return AppLocalization.string("error.authentication_cancelled")
        case .devicePasscodeRequired:
            return AppLocalization.string("error.device_passcode_required")
        case .unexpectedStatus:
            return AppLocalization.string("error.keychain_unavailable")
        case .invalidStoredKey:
            return AppLocalization.string("error.invalid_database_key")
        }
    }
}

/// Owns the only copy of the SQLCipher database key that survives process exit.
///
/// The item never synchronizes to iCloud, becomes unavailable when the device
/// passcode is removed, and requires device-owner presence for every read.
enum DatabaseKeyStore {
    private static let service = "com.laiwenkang.MoneyUp.database-key"
    private static let account = "primary"
    private static let keyLength = 32

    static func loadOrCreateKey(databaseURL: URL) throws -> Data {
        switch loadKey() {
        case let .success(key):
            return key
        case let .failure(error):
            guard case let .unexpectedStatus(status) = error,
                  status == errSecItemNotFound else {
                throw error
            }
            let artifacts = DatabaseKeyCreationPolicy.artifactURLs(
                for: databaseURL
            )
            let exists = artifacts.map {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard DatabaseKeyCreationPolicy.mayCreateKey(
                databaseExists: exists[0],
                writeAheadLogExists: exists[1],
                sharedMemoryExists: exists[2]
            ) else {
                throw DatabaseKeyStoreError.invalidStoredKey
            }
            return try createKey()
        }
    }

    static func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mappedError(for: status)
        }
    }

    private static func loadKey() -> Result<Data, DatabaseKeyStoreError> {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.localizedReason = AppLocalization.string("lock.authentication_reason")
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return .failure(mappedError(for: status))
        }
        guard let key = result as? Data, key.count == keyLength else {
            return .failure(.invalidStoredKey)
        }
        return .success(key)
    }

    private static func createKey() throws -> Data {
        var key = Data(count: keyLength)
        let randomStatus = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, keyLength, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw mappedError(for: randomStatus)
        }

        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            key.resetBytes(in: 0..<key.count)
            throw DatabaseKeyStoreError.devicePasscodeRequired
        }

        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            key.resetBytes(in: 0..<key.count)
            if status == errSecDuplicateItem {
                return try loadKey().get()
            }
            throw mappedError(for: status)
        }
        return key
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private static func mappedError(for status: OSStatus) -> DatabaseKeyStoreError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .authenticationCancelled
        default:
            return .unexpectedStatus(status)
        }
    }
}
