import CryptoKit
import Foundation

extension CloudKitWebClient {
    func upload(_ manifest: CloudBackupManifest, archiveURL: URL) async throws {
        try manifest.validate()
        _ = try await verifiedAccount()
        if let existing = try await lookup(manifest.recordName) {
            guard try Self.manifest(from: existing) == manifest else { throw CloudBackupError.damagedBackup }
            return
        }
        guard archiveURL.isFileURL else { throw CloudBackupError.localStorage }
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        for (index, chunk) in manifest.chunks.enumerated() {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: chunk.byteCount), data.count == chunk.byteCount,
                  CloudBackupManifest.digest(data) == chunk.sha256 else { throw CloudBackupError.damagedBackup }
            hasher.update(data: data)
            try await uploadChunk(data, manifest: manifest, index: index)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256, (try handle.read(upToCount: 1))?.isEmpty != false else {
            throw CloudBackupError.damagedBackup
        }
        _ = try await verifiedAccount()
        let encoded = try JSONEncoder().encode(manifest)
        guard let text = String(data: encoded, encoding: .utf8) else { throw CloudBackupError.damagedBackup }
        try await create(recordName: manifest.recordName, recordType: "MoneyUpBackup", fields: [
            "manifest": .field(.string(text)),
            "bookID": .field(.string(manifest.bookID.uuidString)),
            "createdAt": .field(.integer(Int64((manifest.createdAt.timeIntervalSince1970 * 1_000).rounded())), type: "TIMESTAMP")])
        guard let stored = try await lookup(manifest.recordName),
              try Self.manifest(from: stored) == manifest else { throw CloudBackupError.invalidResponse }
    }

    private func uploadChunk(_ data: Data, manifest: CloudBackupManifest, index: Int) async throws {
        let name = manifest.chunkRecordName(index)
        if let existing = try await lookup(name) {
            try Self.validateChunk(existing, manifest: manifest, index: index)
            return
        }
        let asset = try await uploadAsset(data, recordName: name)
        try await create(recordName: name, recordType: "MoneyUpBackupChunk", fields: [
            "payload": .field(asset, type: "ASSET"),
            "sha256": .field(.string(manifest.chunks[index].sha256)),
            "backupID": .field(.string(manifest.id.uuidString)),
            "index": .field(.integer(Int64(index)))])
    }

    func download(_ selected: CloudBackupManifest, to destination: URL) async throws {
        try selected.validate()
        guard destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else { throw CloudBackupError.localStorage }
        _ = try await verifiedAccount()
        guard let record = try await lookup(selected.recordName),
              try Self.manifest(from: record) == selected else { throw CloudBackupError.missingBackup }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
            attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else {
            throw CloudBackupError.localStorage
        }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        for (index, chunk) in selected.chunks.enumerated() {
            try Task.checkCancellation()
            guard let record = try await lookup(selected.chunkRecordName(index)) else { throw CloudBackupError.damagedBackup }
            try Self.validateChunk(record, manifest: selected, index: index)
            let data = try await downloadAsset(record["fields"]["payload"]["value"], expectedBytes: chunk.byteCount)
            guard CloudBackupManifest.digest(data) == chunk.sha256 else { throw CloudBackupError.damagedBackup }
            hasher.update(data: data)
            try handle.write(contentsOf: data)
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == selected.sha256 else {
            throw CloudBackupError.damagedBackup
        }
        try handle.synchronize()
        complete = true
    }

    func delete(_ selected: CloudBackupManifest) async throws {
        try selected.validate()
        _ = try await verifiedAccount()
        if let record = try await lookup(selected.recordName) {
            guard try Self.manifest(from: record) == selected,
                  let tag = record["recordChangeTag"].string else { throw CloudBackupError.damagedBackup }
            // Hide the recovery point before deleting its chunks. Interrupted
            // cleanup must not leave a selectable but incomplete backup.
            try await modify(.object(["operationType": .string("delete"), "record": .object([
                "recordName": .string(selected.recordName), "recordChangeTag": .string(tag)])]), recordName: selected.recordName)
        }
        for index in selected.chunks.indices {
            try Task.checkCancellation()
            let name = selected.chunkRecordName(index)
            if let record = try await lookup(name) {
                try Self.validateChunk(record, manifest: selected, index: index)
                guard let tag = record["recordChangeTag"].string else { throw CloudBackupError.invalidResponse }
                try await modify(.object(["operationType": .string("delete"), "record": .object([
                    "recordName": .string(name), "recordChangeTag": .string(tag)])]), recordName: name)
            }
        }
    }

    private static func validateChunk(_ record: JSON, manifest: CloudBackupManifest, index: Int) throws {
        try checkError(record)
        guard record["recordName"].string == manifest.chunkRecordName(index),
              record["recordType"].string == "MoneyUpBackupChunk",
              record["fields"]["backupID"]["value"].string == manifest.id.uuidString,
              record["fields"]["index"]["value"].integer == Int64(index),
              record["fields"]["sha256"]["value"].string == manifest.chunks[index].sha256,
              record["fields"]["payload"]["value"]["size"].integer == Int64(manifest.chunks[index].byteCount) else {
            throw CloudBackupError.damagedBackup
        }
    }
}
