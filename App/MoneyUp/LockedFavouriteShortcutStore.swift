import Foundation
import Security

/// Retired: earlier builds could show favourite labels on Locked Quick
/// Capture from a small encrypted file with its own device-only key. Widgets
/// now open the normal Log after unlock, so the only remaining operation
/// deletes whatever such a build left behind.
protocol LockedFavouriteShortcutStoring: Sendable {
    func eraseAll() async throws
}

actor LockedFavouriteShortcutStore: LockedFavouriteShortcutStoring {
    private static let service = "com.laiwenkang.MoneyUp.locked-favourites-key"
    private static let account = "primary"

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
        return base.appendingPathComponent("MoneyUp", isDirectory: true)
            .appendingPathComponent("locked-favourites.bin")
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

/// Deterministic in-memory store for tests and previews: it records whether
/// labels from an earlier build are still present.
actor InMemoryLockedFavouriteShortcutStore: LockedFavouriteShortcutStoring {
    private(set) var holdsRetiredLabels: Bool

    init(holdsRetiredLabels: Bool = false) {
        self.holdsRetiredLabels = holdsRetiredLabels
    }

    func eraseAll() async throws { holdsRetiredLabels = false }
}
