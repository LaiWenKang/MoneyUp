import Foundation
import LocalAuthentication
import Security

enum DatabaseKeyStoreError: Error, Equatable {
    case authenticationCancelled
    case devicePasscodeRequired
    case unexpectedStatus(OSStatus)
    case invalidStoredKey
}

extension DatabaseKeyStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .authenticationCancelled:
            return String(localized: "error.authentication_cancelled")
        case .devicePasscodeRequired:
            return String(localized: "error.device_passcode_required")
        case let .unexpectedStatus(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail ?? String(localized: "error.keychain_unavailable")
        case .invalidStoredKey:
            return String(localized: "error.invalid_database_key")
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

    static func loadOrCreateKey() throws -> Data {
        switch loadKey() {
        case let .success(key):
            return key
        case let .failure(error):
            guard case let .unexpectedStatus(status) = error,
                  status == errSecItemNotFound else {
                throw error
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
        context.localizedReason = String(localized: "lock.authentication_reason")
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
