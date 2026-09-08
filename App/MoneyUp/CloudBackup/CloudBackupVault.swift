import Foundation
import Security

protocol CloudBackupVault: Sendable {
    func load() async throws -> CloudBackupAccount?
    func save(_ account: CloudBackupAccount) async throws
    func rotateToken(_ token: String, connectionID: UUID) async throws
    func pauseAutomatic() async throws
    func enableBackup(connectionID: UUID, consentRevision: UInt64, bookID: UUID,
        password: String, recoveryContextID: UUID) async throws -> CloudBackupAccount
    func recordSuccess(_ date: Date, connectionID: UUID, bookID: UUID,
        recoveryContextID: UUID) async throws -> CloudBackupAccount
    func clear() async throws
}

/// Separate from the database key and the device's system iCloud account.
/// Actor isolation keeps all Keychain work off the main actor.
actor CloudBackupKeychainVault: CloudBackupVault {
    nonisolated static func eraseAllAccounts() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.laiwenkang.MoneyUp.cloud-backup",
            kSecAttrSynchronizable as String: false]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudBackupError.localStorage }
    }
    private let configurationID: String
    init(configurationID: String) { self.configurationID = configurationID }

    func load() throws -> CloudBackupAccount? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, var data = result as? Data, data.count <= 50_000 else {
            throw CloudBackupError.localStorage
        }
        defer { data.resetBytes(in: 0..<data.count) }
        guard let account = try? JSONDecoder().decode(CloudBackupAccount.self, from: data),
              account.isValid, account.configurationID == configurationID else {
            throw CloudBackupError.localStorage
        }
        return account
    }

    func save(_ account: CloudBackupAccount) throws {
        guard account.isValid, account.configurationID == configurationID else {
            throw CloudBackupError.localStorage
        }
        var data = try JSONEncoder().encode(account)
        defer { data.resetBytes(in: 0..<data.count) }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var query = baseQuery
            for (key, value) in attributes { query[key] = value }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw CloudBackupError.localStorage
            }
        } else if result != errSecSuccess { throw CloudBackupError.localStorage }
    }

    func rotateToken(_ token: String, connectionID: UUID) throws {
        guard var account = try load(), account.connectionID == connectionID,
              !token.isEmpty, token.utf8.count <= CloudBackupAccount.maximumTokenBytes else {
            throw CloudBackupError.accountChanged
        }
        account.webToken = token
        try save(account)
    }

    func clear() throws {
        let result = SecItemDelete(baseQuery as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw CloudBackupError.localStorage
        }
    }

    func pauseAutomatic() throws {
        guard var account = try load() else { return }
        account.automaticEnabled = false
        account.consentRevision &+= 1
        try save(account)
    }

    func enableBackup(connectionID: UUID, consentRevision: UInt64, bookID: UUID,
        password: String, recoveryContextID: UUID) throws -> CloudBackupAccount {
        try Task.checkCancellation()
        guard var account = try load(), account.connectionID == connectionID,
              account.consentRevision == consentRevision else { throw CloudBackupError.accountChanged }
        account.bookID = bookID
        account.recoveryPassword = password
        account.recoveryContextID = recoveryContextID
        account.automaticEnabled = true
        try save(account)
        return account
    }

    func recordSuccess(_ date: Date, connectionID: UUID, bookID: UUID,
        recoveryContextID: UUID) throws -> CloudBackupAccount {
        guard var account = try load(), account.connectionID == connectionID,
              account.bookID == bookID, account.recoveryContextID == recoveryContextID else {
            throw CloudBackupError.accountChanged
        }
        account.lastSuccessfulBackup = date
        try save(account)
        return account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.laiwenkang.MoneyUp.cloud-backup",
         kSecAttrAccount as String: configurationID,
         kSecAttrSynchronizable as String: false]
    }
}
