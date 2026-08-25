import CryptoKit
import Foundation
import Security

enum LockedCaptureKind: String, Codable, Sendable {
    case expense
    case income
    case transfer
    case refund
}

struct LockedCapture: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: LockedCaptureKind
    let amountText: String
    let occurredAt: Date
    let payee: String
    let note: String

    init(
        id: UUID = UUID(),
        kind: LockedCaptureKind,
        amountText: String,
        occurredAt: Date = Date(),
        payee: String = "",
        note: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.amountText = amountText
        self.occurredAt = occurredAt
        self.payee = payee
        self.note = note
    }
}

enum LockedCaptureStoreError: Error {
    case unavailable
    case invalidData
    case queueFull
}

extension LockedCaptureStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "capture.error.unavailable")
        case .invalidData:
            String(localized: "capture.error.invalid")
        case .queueFull:
            String(localized: "capture.error.full")
        }
    }
}

/// An append-only encrypted inbox that can be written without Face ID.
///
/// It deliberately contains no account balances, category names, or database
/// key. The separate key is device-only and becomes available only after the
/// first device unlock following a reboot. Captures move into SQLCipher on the
/// next authenticated MoneyUp unlock.
actor LockedCaptureStore {
    private static let service = "com.laiwenkang.MoneyUp.locked-capture-key"
    private static let account = "primary"
    private static let maximumCount = 100

    func all() async throws -> [LockedCapture] {
        guard FileManager.default.fileExists(atPath: try fileURL().path) else { return [] }
        var key = try loadOrCreateKey()
        defer { key.resetBytes(in: 0..<key.count) }
        do {
            let encrypted = try Data(contentsOf: fileURL())
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
            return try JSONDecoder().decode([LockedCapture].self, from: plaintext)
                .sorted { $0.occurredAt < $1.occurredAt }
        } catch let error as LockedCaptureStoreError {
            throw error
        } catch {
            throw LockedCaptureStoreError.invalidData
        }
    }

    func append(_ capture: LockedCapture) async throws {
        var captures = try await all()
        guard captures.count < Self.maximumCount else {
            throw LockedCaptureStoreError.queueFull
        }
        guard !captures.contains(where: { $0.id == capture.id }) else { return }
        captures.append(capture)
        try write(captures)
    }

    func remove(id: UUID) async throws {
        var captures = try await all()
        captures.removeAll { $0.id == id }
        try write(captures)
    }

    private func write(_ captures: [LockedCapture]) throws {
        let url = try fileURL()
        if captures.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }

        var key = try loadOrCreateKey()
        defer { key.resetBytes(in: 0..<key.count) }
        let plaintext = try JSONEncoder().encode(captures)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = sealed.combined else {
            throw LockedCaptureStoreError.unavailable
        }
        try combined.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("MoneyUp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedDirectory.setResourceValues(values)
        return directory.appendingPathComponent("locked-captures.bin")
    }

    private func loadOrCreateKey() throws -> Data {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == 32 {
            return key
        }
        guard status == errSecItemNotFound else {
            throw LockedCaptureStoreError.unavailable
        }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw LockedCaptureStoreError.unavailable
        }
        var add = baseQuery
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            key.resetBytes(in: 0..<key.count)
            throw LockedCaptureStoreError.unavailable
        }
        return key
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
