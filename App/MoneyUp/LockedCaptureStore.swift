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
    static let maximumAmountByteCount = maximumMoneyAmountTextByteCount
    static let maximumPayeeByteCount = 512
    static let maximumNoteByteCount = 2_048

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

    var isStructurallyValid: Bool {
        !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && amountText.utf8.count <= Self.maximumAmountByteCount
            && payee.utf8.count <= Self.maximumPayeeByteCount
            && note.utf8.count <= Self.maximumNoteByteCount
            && occurredAt.timeIntervalSinceReferenceDate.isFinite
    }
}

enum LockedCaptureStoreError: Error, Sendable {
    /// A retryable Keychain or filesystem failure. The ciphertext may still
    /// become readable, so callers must never offer destructive recovery for
    /// this case.
    case unavailable
    /// Ciphertext exists but its device-only key is definitively absent.
    case keyMissing
    /// The key, authenticated ciphertext, or decoded queue is permanently
    /// malformed. Retrying the same bytes cannot recover the captures.
    case invalidData
    case queueFull

    var isDefinitivelyUnrecoverable: Bool {
        switch self {
        case .keyMissing, .invalidData:
            true
        case .unavailable, .queueFull:
            false
        }
    }
}

extension LockedCaptureStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "capture.error.unavailable")
        case .keyMissing, .invalidData:
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
    // Covers the worst-case JSON escaping of every bounded field in 100
    // captures while preventing a corrupt file from causing an unbounded read.
    private static let maximumEncryptedByteCount = 2_000_000

    func all() async throws -> [LockedCapture] {
        try Task.checkCancellation()
        let url: URL
        do {
            url = try fileURL()
        } catch {
            throw LockedCaptureStoreError.unavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // Existing ciphertext without its device-only key is a recovery error,
        // never a reason to install a random replacement key.
        var key = try loadExistingKey()
        defer { key.resetBytes(in: 0..<key.count) }
        let fileSize: Int?
        do {
            fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LockedCaptureStoreError.unavailable
        }
        guard fileSize.map({ $0 <= Self.maximumEncryptedByteCount }) != false else {
            throw LockedCaptureStoreError.invalidData
        }

        let encrypted: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            encrypted = try BoundedFileReader.read(
                from: handle,
                maximumByteCount: Self.maximumEncryptedByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Permission, protection-state, and transient I/O errors are
            // retryable. They are not evidence that the queue is corrupt.
            throw LockedCaptureStoreError.unavailable
        }
        guard !encrypted.isEmpty,
              encrypted.count <= Self.maximumEncryptedByteCount else {
            throw LockedCaptureStoreError.invalidData
        }
        try Task.checkCancellation()

        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
            let captures = try JSONDecoder().decode([LockedCapture].self, from: plaintext)
            guard captures.count <= Self.maximumCount,
                  Set(captures.map(\.id)).count == captures.count,
                  captures.allSatisfy(\.isStructurallyValid) else {
                throw LockedCaptureStoreError.invalidData
            }
            // JSON array order is the authoritative FIFO. Wall-clock rollback
            // must not reorder captures that were appended sequentially.
            return captures
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The key was read successfully and the entire ciphertext was read
            // successfully. Authentication/decoding failure is therefore a
            // stable, destructive-recovery-eligible condition.
            throw LockedCaptureStoreError.invalidData
        }
    }

    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int {
        let captures = try await all()
        let updated = try Self.queueByAppending(capture, to: captures)
        guard updated.count != captures.count else {
            return captures.count
        }
        try write(updated)
        return updated.count
    }

    /// Applies the append contract without touching Keychain or disk so its
    /// duplicate-at-capacity boundary remains directly regression-testable.
    static func queueByAppending(
        _ capture: LockedCapture,
        to captures: [LockedCapture]
    ) throws -> [LockedCapture] {
        guard capture.isStructurallyValid else {
            throw LockedCaptureStoreError.invalidData
        }
        guard !captures.contains(where: { $0.id == capture.id }) else {
            return captures
        }
        guard captures.count < Self.maximumCount else {
            throw LockedCaptureStoreError.queueFull
        }
        var captures = captures
        captures.append(capture)
        return captures
    }

    @discardableResult
    func remove(id: UUID) async throws -> Int {
        var captures = try await all()
        captures.removeAll { $0.id == id }
        try write(captures)
        return captures.count
    }

    func eraseAll() async throws {
        let url: URL
        do {
            url = try fileURL()
        } catch {
            throw LockedCaptureStoreError.unavailable
        }
        // Delete the key first: if filesystem cleanup is interrupted, the
        // remaining ciphertext is already unrecoverable and a retry can
        // converge by removing the orphan file. Never leave readable capture
        // data merely because a later unlink failed.
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LockedCaptureStoreError.unavailable
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw LockedCaptureStoreError.unavailable
            }
        }
    }

    private func write(_ captures: [LockedCapture]) throws {
        let url = try fileURL()
        if captures.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }

        var key = FileManager.default.fileExists(atPath: url.path)
            ? try loadExistingKey()
            : try loadOrCreateKey()
        defer { key.resetBytes(in: 0..<key.count) }
        let plaintext = try JSONEncoder().encode(captures)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = sealed.combined,
              combined.count <= Self.maximumEncryptedByteCount else {
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
        do {
            return try loadExistingKey()
        } catch LockedCaptureStoreError.keyMissing {
            // Continue only when Keychain explicitly reports item-not-found.
        }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if lookupStatus == errSecSuccess {
            guard let key = result as? Data, key.count == 32 else {
                throw LockedCaptureStoreError.invalidData
            }
            return key
        }
        guard lookupStatus == errSecItemNotFound else {
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

    private func loadExistingKey() throws -> Data {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let key = result as? Data, key.count == 32 else {
                throw LockedCaptureStoreError.invalidData
            }
            return key
        }
        if status == errSecItemNotFound {
            throw LockedCaptureStoreError.keyMissing
        }
        throw LockedCaptureStoreError.unavailable
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
