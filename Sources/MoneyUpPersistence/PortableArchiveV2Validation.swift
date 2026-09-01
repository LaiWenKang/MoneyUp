import CryptoKit
import Foundation
import MoneyUpCore

extension PortableArchiveV2 {
    private struct ParsedHeaderFields {
        let chunkCount: Int
        let recordCount: Int
        let payloadByteCount: Int
        let plaintextByteCount: Int
        let schemaBits: UInt32
        let createdAtBits: UInt64
        let salt: Data
        let noncePrefix: Data
    }

    static func metrics(
        for records: [StoredRecordSnapshot]
    ) throws -> DatabaseStorageMetrics {
        var payloadByteCount = 0
        var recordIDByteCount = 0
        var collectionByteCount = 0
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let collectionCount = record.collection.utf8.count
            let recordIDCount = record.recordID.utf8.count
            try validate(
                record: record,
                collectionByteCount: collectionCount,
                recordIDByteCount: recordIDCount
            )
            payloadByteCount = try checkedAdd(
                payloadByteCount,
                record.payload.count
            )
            recordIDByteCount = try checkedAdd(recordIDByteCount, recordIDCount)
            collectionByteCount = try checkedAdd(
                collectionByteCount,
                collectionCount
            )
        }
        return DatabaseStorageMetrics(
            recordCount: records.count,
            payloadByteCount: payloadByteCount,
            recordIDByteCount: recordIDByteCount,
            collectionByteCount: collectionByteCount
        )
    }

    static func metadata(
        schemaVersion: Int32,
        createdAt: Date,
        metrics: DatabaseStorageMetrics
    ) throws -> Metadata {
        guard schemaVersion >= 0,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              metrics.recordCount >= 0,
              metrics.recordCount <= maximumRecordCount,
              metrics.payloadByteCount >= 0,
              metrics.payloadByteCount
                <= PortableArchive.maximumStoredPayloadByteCount,
              metrics.recordIDByteCount >= 0,
              metrics.collectionByteCount >= 0 else {
            throw PortableArchiveError.archiveTooLarge
        }
        var plaintextByteCount = try checkedMultiply(
            metrics.recordCount,
            recordHeaderByteCount
        )
        plaintextByteCount = try checkedAdd(
            plaintextByteCount,
            metrics.payloadByteCount
        )
        plaintextByteCount = try checkedAdd(
            plaintextByteCount,
            metrics.recordIDByteCount
        )
        plaintextByteCount = try checkedAdd(
            plaintextByteCount,
            metrics.collectionByteCount
        )
        let chunkCount = max(
            1,
            try checkedAdd(plaintextByteCount, chunkByteCount - 1)
                / chunkByteCount
        )
        let framedOverhead = try checkedMultiply(
            chunkCount,
            framePrefixByteCount + tagByteCount
        )
        let archiveByteCount = try checkedAdd(
            headerByteCount,
            try checkedAdd(plaintextByteCount, framedOverhead)
        )
        guard PortableArchive.isWithinNewArchiveByteLimit(archiveByteCount),
              metrics.recordCount <= Int(UInt32.max),
              chunkCount <= Int(UInt32.max) else {
            throw PortableArchiveError.archiveTooLarge
        }
        return Metadata(
            archiveVersion: PortableArchive.currentVersion,
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            recordCount: metrics.recordCount,
            payloadByteCount: metrics.payloadByteCount,
            plaintextByteCount: plaintextByteCount,
            chunkCount: chunkCount
        )
    }

    static func makeHeader(
        metadata: Metadata,
        salt: Data,
        noncePrefix: Data
    ) throws -> Header {
        guard salt.count == 16, noncePrefix.count == 8 else {
            throw PortableArchiveError.invalidArchive
        }
        var encoded = Data()
        encoded.reserveCapacity(headerByteCount)
        encoded.append(PortableArchive.magic)
        encoded.append(UInt8(PortableArchive.currentVersion))
        encoded.append(flags)
        encoded.appendBigEndian(UInt16(headerByteCount))
        encoded.appendBigEndian(UInt32(PortableArchive.iterationCount))
        encoded.appendBigEndian(UInt32(chunkByteCount))
        encoded.appendBigEndian(UInt32(metadata.chunkCount))
        encoded.appendBigEndian(UInt32(metadata.recordCount))
        encoded.appendBigEndian(UInt64(metadata.payloadByteCount))
        encoded.appendBigEndian(UInt64(metadata.plaintextByteCount))
        encoded.appendBigEndian(UInt32(bitPattern: metadata.schemaVersion))
        // Foundation stores Date relative to its reference date. Preserve that
        // exact bit pattern instead of translating through the Unix epoch,
        // which can lose one ULP and make an otherwise identical snapshot
        // compare unequal after a round trip.
        encoded.appendBigEndian(
            metadata.createdAt.timeIntervalSinceReferenceDate.bitPattern
        )
        encoded.append(salt)
        encoded.append(noncePrefix)
        guard encoded.count == headerByteCount else {
            throw PortableArchiveError.invalidArchive
        }
        return Header(
            metadata: metadata,
            salt: salt,
            noncePrefix: noncePrefix,
            encoded: encoded
        )
    }

    static func parseHeader(
        _ encoded: Data,
        fileByteCount: Int
    ) throws -> Header {
        var cursor = try validatedHeaderPrefix(encoded)
        let fields = try parsedHeaderFields(encoded, cursor: &cursor)
        guard cursor == headerByteCount else {
            throw PortableArchiveError.invalidArchive
        }
        let metadata = try validatedHeaderMetadata(fields)
        try validateArchiveByteCount(metadata, fileByteCount: fileByteCount)
        return Header(
            metadata: metadata,
            salt: fields.salt,
            noncePrefix: fields.noncePrefix,
            encoded: encoded
        )
    }

    private static func validatedHeaderPrefix(_ encoded: Data) throws -> Int {
        guard encoded.count == headerByteCount,
              encoded.prefix(PortableArchive.magic.count)
                == PortableArchive.magic else {
            throw PortableArchiveError.invalidArchive
        }
        var cursor = PortableArchive.magic.count
        let version = Int(encoded[cursor])
        cursor += 1
        guard version == PortableArchive.currentVersion else {
            throw PortableArchiveError.unsupportedVersion(version)
        }
        guard encoded[cursor] == flags else {
            throw PortableArchiveError.invalidArchive
        }
        cursor += 1
        guard try encoded.decodeUInt16(at: cursor) == UInt16(headerByteCount) else {
            throw PortableArchiveError.invalidArchive
        }
        cursor += 2
        guard try encoded.decodeUInt32(at: cursor)
                == UInt32(PortableArchive.iterationCount) else {
            throw PortableArchiveError.invalidArchive
        }
        cursor += 4
        guard try encoded.decodeUInt32(at: cursor) == UInt32(chunkByteCount) else {
            throw PortableArchiveError.invalidArchive
        }
        cursor += 4
        return cursor
    }

    private static func parsedHeaderFields(
        _ encoded: Data,
        cursor: inout Int
    ) throws -> ParsedHeaderFields {
        let chunkCount = Int(try encoded.decodeUInt32(at: cursor))
        cursor += 4
        let recordCount = Int(try encoded.decodeUInt32(at: cursor))
        cursor += 4
        let payloadByteCount64 = try encoded.decodeUInt64(at: cursor)
        cursor += 8
        let plaintextByteCount64 = try encoded.decodeUInt64(at: cursor)
        cursor += 8
        guard payloadByteCount64 <= UInt64(Int.max),
              plaintextByteCount64 <= UInt64(Int.max) else {
            throw PortableArchiveError.archiveTooLarge
        }
        let schemaBits = try encoded.decodeUInt32(at: cursor)
        cursor += 4
        let createdAtBits = try encoded.decodeUInt64(at: cursor)
        cursor += 8
        let salt = Data(encoded[cursor..<cursor + 16])
        cursor += 16
        let noncePrefix = Data(encoded[cursor..<cursor + 8])
        cursor += 8
        return ParsedHeaderFields(
            chunkCount: chunkCount,
            recordCount: recordCount,
            payloadByteCount: Int(payloadByteCount64),
            plaintextByteCount: Int(plaintextByteCount64),
            schemaBits: schemaBits,
            createdAtBits: createdAtBits,
            salt: salt,
            noncePrefix: noncePrefix
        )
    }

    private static func validatedHeaderMetadata(
        _ fields: ParsedHeaderFields
    ) throws -> Metadata {
        let metrics = DatabaseStorageMetrics(
            recordCount: fields.recordCount,
            payloadByteCount: fields.payloadByteCount,
            recordIDByteCount: 0,
            collectionByteCount: 0
        )
        let createdAt = Date(
            timeIntervalSinceReferenceDate: Double(bitPattern: fields.createdAtBits)
        )
        let metadata = Metadata(
            archiveVersion: PortableArchive.currentVersion,
            schemaVersion: Int32(bitPattern: fields.schemaBits),
            createdAt: createdAt,
            recordCount: metrics.recordCount,
            payloadByteCount: metrics.payloadByteCount,
            plaintextByteCount: fields.plaintextByteCount,
            chunkCount: fields.chunkCount
        )
        let expectedChunkCount = max(
            1,
            try checkedAdd(
                metadata.plaintextByteCount,
                chunkByteCount - 1
            ) / chunkByteCount
        )
        guard metadata.schemaVersion >= 0,
              metadata.createdAt.timeIntervalSinceReferenceDate.isFinite,
              metadata.recordCount >= 0,
              metadata.recordCount <= maximumRecordCount,
              metadata.payloadByteCount >= 0,
              metadata.payloadByteCount
                <= PortableArchive.maximumStoredPayloadByteCount,
              metadata.plaintextByteCount >= 0,
              metadata.plaintextByteCount
                >= metadata.payloadByteCount,
              metadata.chunkCount == expectedChunkCount else {
            throw PortableArchiveError.invalidArchive
        }
        return metadata
    }

    private static func validateArchiveByteCount(
        _ metadata: Metadata,
        fileByteCount: Int
    ) throws {
        let expectedArchiveByteCount = try checkedAdd(
            headerByteCount,
            try checkedAdd(
                metadata.plaintextByteCount,
                try checkedMultiply(
                    metadata.chunkCount,
                    framePrefixByteCount + tagByteCount
                )
            )
        )
        guard expectedArchiveByteCount == fileByteCount,
              PortableArchive.isWithinArchiveByteLimit(fileByteCount) else {
            throw PortableArchiveError.invalidArchive
        }
    }

    static func validate(
        record: StoredRecordSnapshot,
        collectionByteCount: Int,
        recordIDByteCount: Int
    ) throws {
        guard !record.collection.isEmpty,
              collectionByteCount <= maximumCollectionByteCount,
              !record.recordID.isEmpty,
              recordIDByteCount <= maximumRecordIDByteCount,
              !record.payload.isEmpty,
              record.payload.count <= maximumRecordPayloadByteCount,
              record.updatedAt.isFinite else {
            throw PortableArchiveError.invalidArchive
        }
    }

    static func expectedPlaintextLength(
        chunkIndex: Int,
        metadata: Metadata
    ) -> Int {
        if chunkIndex < metadata.chunkCount - 1 { return chunkByteCount }
        return metadata.plaintextByteCount
            - (metadata.chunkCount - 1) * chunkByteCount
    }

    static func associatedData(
        header: Data,
        chunkIndex: Int,
        plaintextLength: Int
    ) -> Data {
        var data = header
        data.appendBigEndian(UInt32(chunkIndex))
        data.appendBigEndian(UInt32(plaintextLength))
        return data
    }

    static func nonce(
        prefix: Data,
        index: Int
    ) throws -> AES.GCM.Nonce {
        guard prefix.count == 8,
              index >= 0,
              index <= Int(UInt32.max) else {
            throw PortableArchiveError.invalidArchive
        }
        var nonceData = prefix
        nonceData.appendBigEndian(UInt32(index))
        do {
            return try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw PortableArchiveError.invalidArchive
        }
    }

    static func writeAtomically(
        to destinationURL: URL,
        body: (FileHandle) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporaryURL = directory.appendingPathComponent(
            ".moneyup-archive-\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: temporaryURL) }
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try body(handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        committed = true
    }

    static func fileByteCount(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let byteCount = values.fileSize, byteCount >= 0 else {
            throw PortableArchiveError.invalidArchive
        }
        return byteCount
    }

    static func readExactly(
        _ byteCount: Int,
        from handle: FileHandle
    ) throws -> Data {
        guard byteCount >= 0 else {
            throw PortableArchiveError.invalidArchive
        }
        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            try Task.checkCancellation()
            let next = try handle.read(upToCount: byteCount - data.count)
                ?? Data()
            guard !next.isEmpty else {
                throw PortableArchiveError.invalidArchive
            }
            data.append(next)
        }
        return data
    }

    static func decodeUInt32(_ data: Data) throws -> UInt32 {
        try data.decodeUInt32(at: 0)
    }

    static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, result >= 0 else {
            throw PortableArchiveError.archiveTooLarge
        }
        return result
    }

    static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow, result >= 0 else {
            throw PortableArchiveError.archiveTooLarge
        }
        return result
    }
}
