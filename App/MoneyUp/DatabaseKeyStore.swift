import Foundation
import LocalAuthentication
import Security

enum DatabaseKeyStoreError: Error, Equatable, Sendable {
    case authenticationCancelled
    case devicePasscodeRequired
    case unexpectedStatus(OSStatus)
    case invalidStoredKey
    /// The device-bound Keychain item is gone while at least one SQLCipher
    /// artifact still exists. This is a recovery state, never permission to
    /// create a replacement key beside unreadable ciphertext.
    case missingDeviceBoundKey
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
        case .missingDeviceBoundKey:
            return AppLocalization.string("error.missing_device_bound_key")
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
                throw DatabaseKeyStoreError.missingDeviceBoundKey
            }
            return try createKey()
        }
    }

    /// Verifies the device can protect a replacement key, then generates it
    /// for the explicit key-cliff transaction. This does not change Keychain
    /// or the live database and is therefore safe before archive validation.
    static func generateRecoveryKey() throws -> Data {
        try requireDevicePasscodeForRecovery()
        _ = try deviceBoundAccessControl()
        return try generateRandomKey()
    }

    /// `SecAccessControlCreateWithFlags` constructs a policy object but does
    /// not prove that the device currently has a passcode. This non-interactive
    /// LocalAuthentication check performs that preflight without creating a
    /// temporary Keychain item or leaving any cleanup artifact behind.
    static func requireDevicePasscodeForRecovery(
        canEvaluateOwnerAuthentication: () -> Bool = {
            LAContext().canEvaluatePolicy(
                .deviceOwnerAuthentication,
                error: nil
            )
        }
    ) throws {
        guard canEvaluateOwnerAuthentication() else {
            throw DatabaseKeyStoreError.devicePasscodeRequired
        }
    }

    /// Stores an already-validated recovery candidate's key under the same
    /// device-bound policy as a first-install key. The caller owns the
    /// crash-consistent filesystem transaction and must call this only after
    /// its non-secret durable recovery marker exists.
    static func storeRecoveryKey(
        _ key: Data,
        canEvaluateOwnerAuthentication: () -> Bool = {
            LAContext().canEvaluatePolicy(
                .deviceOwnerAuthentication,
                error: nil
            )
        }
    ) throws {
        // Candidate validation can take long enough for the device passcode
        // state to change. Recheck at the final Keychain boundary so a missing
        // passcode has the same stable error as the initial preflight without
        // depending on newer-SDK-only OSStatus values.
        try requireDevicePasscodeForRecovery(
            canEvaluateOwnerAuthentication: canEvaluateOwnerAuthentication
        )
        _ = try storeKey(key, loadExistingOnDuplicate: false)
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
        var key = try generateRandomKey()
        do {
            if let existing = try storeKey(
                key,
                loadExistingOnDuplicate: true
            ) {
                key.resetBytes(in: 0..<key.count)
                return existing
            }
            return key
        } catch {
            key.resetBytes(in: 0..<key.count)
            throw error
        }
    }

    private static func generateRandomKey() throws -> Data {
        var key = Data(count: keyLength)
        let randomStatus = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, keyLength, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            key.resetBytes(in: 0..<key.count)
            throw mappedError(for: randomStatus)
        }
        return key
    }

    private static func storeKey(
        _ key: Data,
        loadExistingOnDuplicate: Bool
    ) throws -> Data? {
        guard key.count == keyLength else {
            throw DatabaseKeyStoreError.invalidStoredKey
        }

        let accessControl = try deviceBoundAccessControl()

        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem, loadExistingOnDuplicate {
                return try loadKey().get()
            }
            throw mappedError(for: status)
        }
        return nil
    }

    private static func deviceBoundAccessControl() throws -> SecAccessControl {
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            throw DatabaseKeyStoreError.devicePasscodeRequired
        }
        return accessControl
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func mappedError(for status: OSStatus) -> DatabaseKeyStoreError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .authenticationCancelled
        default:
            return .unexpectedStatus(status)
        }
    }
}
