import CryptoKit
import Foundation
import MoneyUpPersistence

enum CloudBackupArchive {
    static func verifyUploadedArchive(_ manifest: CloudBackupManifest, using client: CloudKitWebClient,
        password: String) async throws {
        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUp-Cloud-Verification-\(UUID().uuidString).moneyup")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await client.download(manifest, to: downloaded)
        let verification = Task.detached(priority: .utility) {
            try PortableArchive.verify(from: downloaded, password: password)
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: { verification.cancel() }
    }

    static func manifest(for fileURL: URL, bookID: UUID, id: UUID = UUID(),
        createdAt: Date = Date()) throws -> CloudBackupManifest {
        guard fileURL.isFileURL else { throw CloudBackupError.localStorage }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              PortableArchive.isWithinArchiveByteLimit(size) else { throw CloudBackupError.damagedBackup }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var chunks: [CloudBackupManifest.Chunk] = []
        var count = 0
        while let data = try handle.read(upToCount: CloudBackupManifest.chunkByteCount), !data.isEmpty {
            try Task.checkCancellation()
            count += data.count
            guard count <= size else { throw CloudBackupError.damagedBackup }
            hasher.update(data: data)
            chunks.append(.init(byteCount: data.count, sha256: CloudBackupManifest.digest(data)))
        }
        let result = CloudBackupManifest(version: 1, id: id, bookID: bookID, createdAt: createdAt,
            byteCount: count, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), chunks: chunks)
        guard count == size else { throw CloudBackupError.damagedBackup }
        try result.validate()
        return result
    }
}

struct CloudBackupPendingUpload: Codable, Equatable, Sendable {
    let accountIdentity: String
    let recoveryContextID: UUID
    let manifest: CloudBackupManifest
}

/// A file-backed outbox makes retries reuse the same immutable backup identity.
/// Nothing is listed remotely until every encrypted chunk has been committed.
actor CloudBackupOutbox {
    let directory: URL
    let accountIdentity: String
    let recoveryContextID: UUID
    var archiveURL: URL { directory.appendingPathComponent("pending.moneyup") }
    private var metadataURL: URL { directory.appendingPathComponent("pending.json") }

    init(root: URL, configurationID: String, userRecordName: String, bookID: UUID, recoveryContextID: UUID) throws {
        guard root.isFileURL else { throw CloudBackupError.localStorage }
        accountIdentity = CloudBackupManifest.digest(Data("\(configurationID)/\(userRecordName)".utf8))
        self.recoveryContextID = recoveryContextID
        directory = root.appendingPathComponent(accountIdentity, isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(recoveryContextID.uuidString, isDirectory: true)
    }

    static func rootURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CloudBackupError.localStorage
        }
        return base.appendingPathComponent("MoneyUpCloudBackup", isDirectory: true)
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    func pending(bookID: UUID) throws -> CloudBackupManifest? {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: metadataURL)
        defer { try? handle.close() }
        let data = try BoundedFileReader.read(from: handle, maximumByteCount: 32_768)
        let pending = try JSONDecoder().decode(CloudBackupPendingUpload.self, from: data)
        guard pending.accountIdentity == accountIdentity, pending.manifest.bookID == bookID,
              pending.recoveryContextID == recoveryContextID else {
            throw CloudBackupError.accountChanged
        }
        try pending.manifest.validate()
        let current = try CloudBackupArchive.manifest(for: archiveURL, bookID: bookID,
            id: pending.manifest.id, createdAt: pending.manifest.createdAt)
        guard current == pending.manifest else { throw CloudBackupError.damagedBackup }
        return pending.manifest
    }

    func stage(bookID: UUID) throws -> CloudBackupManifest {
        let manifest = try CloudBackupArchive.manifest(for: archiveURL, bookID: bookID)
        let data = try JSONEncoder().encode(CloudBackupPendingUpload(accountIdentity: accountIdentity,
            recoveryContextID: recoveryContextID, manifest: manifest))
        try data.write(to: metadataURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return manifest
    }

    func complete(_ manifest: CloudBackupManifest) throws {
        guard try pending(bookID: manifest.bookID) == manifest else { throw CloudBackupError.damagedBackup }
        // Remove the marker first. A crash leaves only an encrypted scratch
        // archive, never a marker that points at an already-deleted file.
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.removeItem(at: archiveURL)
    }
}
