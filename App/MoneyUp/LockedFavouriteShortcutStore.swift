import CryptoKit
import Foundation
import MoneyUpCore
import Security

/// The part of a favourite that may be shown on Locked Quick Capture when the
/// owner turns on "Show favourites while locked". It carries no account,
/// category, balance, or book identifier; after unlock the exact favourite is
/// matched again inside the encrypted book.
struct LockedFavouriteShortcut: Codable, Equatable, Identifiable, Sendable {
    static let maximumCount = QuickLogFavourite.maximumCount

    let id: UUID
    let name: String
    let kind: LockedCaptureKind
    let amountText: String?
    let payee: String
    let note: String

    /// The title a locked capture records, so promotion can find the exact
    /// favourite again. A favourite without its own title uses its name.
    var capturePayee: String { payee.isEmpty ? name : payee }

    /// "3.20", not "3.2": a figure with cents shows two places. The currency
    /// is not known while locked, so no symbol is invented.
    var displayAmount: String? {
        guard let amountText, let value = decimalAmount(from: amountText) else { return amountText }
        var source = value
        var whole = Decimal.zero
        NSDecimalRound(&whole, &source, 0, .down)
        let hasFraction = whole != value
        return NSDecimalNumber(decimal: value).doubleValue.formatted(
            .number.precision(.fractionLength(hasFraction ? 2 : 0)).grouping(.never)
        )
    }

    init(_ favourite: QuickLogFavourite, locale: Locale = .current) {
        id = favourite.id
        name = favourite.name
        kind = favourite.kind == .income ? .income : .expense
        amountText = favourite.amount.map { editableAmount($0, locale: locale) }
        payee = favourite.payee
        note = favourite.note
    }

    var isStructurallyValid: Bool {
        !name.isEmpty
            && name.count <= QuickLogFavourite.maximumNameLength
            && capturePayee.utf8.count <= LockedCapture.maximumPayeeByteCount
            && note.utf8.count <= LockedCapture.maximumNoteByteCount
            && (amountText?.utf8.count ?? 0) <= LockedCapture.maximumAmountByteCount
            && (kind == .expense || kind == .income)
    }
}

protocol LockedFavouriteShortcutStoring: Sendable {
    /// Fails closed: any unreadable, missing, or malformed state reads empty.
    func all() async -> [LockedFavouriteShortcut]
    func replace(with shortcuts: [LockedFavouriteShortcut]) async throws
    func eraseAll() async throws
}

/// A small encrypted file readable after the first device unlock, like the
/// locked-capture inbox, with its own device-only key. It exists only while
/// the owner has opted in; turning the option off or erasing deletes both.
actor LockedFavouriteShortcutStore: LockedFavouriteShortcutStoring {
    private static let service = "com.laiwenkang.MoneyUp.locked-favourites-key"
    private static let account = "primary"
    private static let maximumEncryptedByteCount = 64_000
    static let durableWriteOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication
    ]

    func all() async -> [LockedFavouriteShortcut] {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              var key = try? loadKey(creating: false) else { return [] }
        defer { key.resetBytes(in: 0..<key.count) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let encrypted = try? BoundedFileReader.read(
                  from: handle, maximumByteCount: Self.maximumEncryptedByteCount
              ),
              let box = try? AES.GCM.SealedBox(combined: encrypted),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let shortcuts = try? JSONDecoder().decode([LockedFavouriteShortcut].self, from: plaintext),
              shortcuts.count <= LockedFavouriteShortcut.maximumCount,
              Set(shortcuts.map(\.id)).count == shortcuts.count,
              shortcuts.allSatisfy(\.isStructurallyValid) else { return [] }
        return shortcuts
    }

    func replace(with shortcuts: [LockedFavouriteShortcut]) async throws {
        let bounded = Array(shortcuts.filter(\.isStructurallyValid)
            .prefix(LockedFavouriteShortcut.maximumCount))
        guard !bounded.isEmpty else {
            try await eraseAll()
            return
        }
        let url = try fileURL()
        var key = try loadKey(creating: true)
        defer { key.resetBytes(in: 0..<key.count) }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(bounded), using: SymmetricKey(data: key))
        guard let combined = sealed.combined,
              combined.count <= Self.maximumEncryptedByteCount else {
            throw LockedCaptureStoreError.unavailable
        }
        try combined.write(to: url, options: Self.durableWriteOptions)
    }

    /// Key first, so an interrupted cleanup never leaves readable labels.
    func eraseAll() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LockedCaptureStoreError.unavailable
        }
        let url = try fileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("MoneyUp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("locked-favourites.bin")
    }

    private func loadKey(creating: Bool) throws -> Data {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == 32 { return key }
        guard status == errSecItemNotFound, creating else {
            throw LockedCaptureStoreError.unavailable
        }
        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard randomStatus == errSecSuccess else { throw LockedCaptureStoreError.unavailable }
        var add = baseQuery
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
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

/// Deterministic in-memory store for tests and previews.
actor InMemoryLockedFavouriteShortcutStore: LockedFavouriteShortcutStoring {
    private var shortcuts: [LockedFavouriteShortcut]

    init(_ shortcuts: [LockedFavouriteShortcut] = []) {
        self.shortcuts = shortcuts
    }

    func all() async -> [LockedFavouriteShortcut] { shortcuts }

    func replace(with shortcuts: [LockedFavouriteShortcut]) async throws {
        self.shortcuts = Array(shortcuts.filter(\.isStructurallyValid)
            .prefix(LockedFavouriteShortcut.maximumCount))
    }

    func eraseAll() async throws { shortcuts = [] }
}
