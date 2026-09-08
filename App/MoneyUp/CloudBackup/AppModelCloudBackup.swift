import Foundation
import MoneyUpPersistence

extension AppModel {
    func eraseCloudBackupLocalStateIfProduction() async throws {
        await cloudBackupController?.disconnect()
        // Fixtures inject a database URL and must never touch production
        // Keychain items or the production outbox directory.
        guard databaseURLForErase == nil else { return }
        try await Task.detached(priority: .userInitiated) {
            try CloudBackupKeychainVault.eraseAllAccounts()
            let root = try CloudBackupOutbox.rootURL()
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }.value
    }

    func cloudBackupBookID(createIfMissing: Bool = false) async throws -> UUID? {
        guard state == .ready else { throw AppModelError.locked }
        if !createIfMissing {
            let generation = storeGeneration
            let revision = logicalBookRevision
            let identity = try await requireStore().fetch(CloudBackupBookIdentity.self,
                id: CloudBackupBookIdentity.recordID, from: .cloudBackupIdentity)
            guard ownsStoreGeneration(generation), logicalBookRevision == revision, state == .ready else {
                throw AppModelError.locked
            }
            return identity?.id
        }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        defer { endLifecycleMutation() }
        let store = try requireStore()
        if let identity = try await store.fetch(CloudBackupBookIdentity.self,
            id: CloudBackupBookIdentity.recordID, from: .cloudBackupIdentity) { return identity.id }
        guard createIfMissing else { return nil }
        let identity = CloudBackupBookIdentity(id: UUID())
        try await store.upsert(identity, id: CloudBackupBookIdentity.recordID, in: .cloudBackupIdentity)
        return identity.id
    }
}
