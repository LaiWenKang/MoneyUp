import CryptoKit
import Foundation

/// Version 2 of the portable archive is a deterministic binary stream whose
/// header and every plaintext chunk are authenticated together. The fixed
/// chunk ceiling bounds encryption/decryption memory independently of the
/// total book size, while the authenticated chunk count rejects truncation,
/// appends, duplication, and reordering.
enum PortableArchiveV2 {
    static let headerByteCount = 80
    static let chunkByteCount = 1_048_576
    static let tagByteCount = 16
    static let framePrefixByteCount = 4
    static let maximumRecordCount = 100_000
    static let maximumCollectionByteCount = 256
    static let maximumRecordIDByteCount = RecordWrite.maximumRecordIDByteCount
    static let maximumRecordPayloadByteCount =
        RecordWrite.maximumReceiptPayloadByteCount

    struct Metadata: Equatable, Sendable {
        let schemaVersion: Int32
        let createdAt: Date
        let recordCount: Int
        let payloadByteCount: Int
        let plaintextByteCount: Int
        let chunkCount: Int
    }

    private struct Header {
        let metadata: Metadata
        let salt: Data
        let noncePrefix: Data
        let encoded: Data
    }

    private static let recordHeaderByteCount = 24
    private static let flags: UInt8 = 0

    static func seal(
        _ snapshot: DatabaseSnapshot,
        password: String
    ) throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUp-Archive-\(UUID().uuidString).moneyup")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try seal(snapshot, password: password, to: temporaryURL)
        let archive = try Data(contentsOf: temporaryURL)
        guard PortableArchive.isWithinArchiveByteLimit(archive.count) else {
            throw PortableArchiveError.archiveTooLarge
        }
        return archive
    }

    static func seal(
        _ snapshot: DatabaseSnapshot,
        password: String,
        to destinationURL: URL
    ) throws {
        let metrics = try metrics(for: snapshot.records)
        try seal(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            metrics: metrics,
            password: password,
            to: destinationURL
        ) { consume in
            for (index, record) in snapshot.records.enumerated() {
                if index.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                try consume(record)
            }
        }
    }

    /// Store-level entry point. `enumerateRecords` may step a SQL cursor and
    /// therefore never needs to construct a `[StoredRecordSnapshot]`.
    static func seal(
        schemaVersion: Int32,
        createdAt: Date,
        metrics: DatabaseStorageMetrics,
        password: String,
        to destinationURL: URL,
        enumerateRecords: (
            _ consume: (StoredRecordSnapshot) throws -> Void
        ) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let passwordData = try PortableArchive.validatedPasswordData(password)
        let metadata = try metadata(
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            metrics: metrics
        )
        let salt = PortableArchive.randomData(count: 16)
        let noncePrefix = PortableArchive.randomData(count: 8)
        let header = try makeHeader(
            metadata: metadata,
            salt: salt,
            noncePrefix: noncePrefix
        )
        let key = try PortableArchive.deriveKey(
            passwordData: passwordData,
            salt: salt,
            iterations: PortableArchive.iterationCount
        )
        try Task.checkCancellation()

        try writeAtomically(to: destinationURL) { handle in
            try handle.write(contentsOf: header.encoded)
            let writer = ChunkWriter(handle: handle, header: header, key: key)
            try enumerateRecords { record in
                try writer.append(record)
            }
            try writer.finish()
        }
    }

    static func open(
        _ archive: Data,
        password: String
    ) throws -> DatabaseSnapshot {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUp-Restore-\(UUID().uuidString).moneyup")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try archive.write(to: temporaryURL, options: [.atomic])
        return try open(temporaryURL, password: password)
    }

    static func open(
        _ sourceURL: URL,
        password: String
    ) throws -> DatabaseSnapshot {
        var records: [StoredRecordSnapshot] = []
        let metadata = try read(from: sourceURL, password: password) { record in
            records.append(record)
        }
        return DatabaseSnapshot(
            schemaVersion: metadata.schemaVersion,
            createdAt: metadata.createdAt,
            records: records
        )
    }

    /// Reads either archive generation from a file. Version 2 invokes the
    /// callback once per authenticated record; legacy version 1 is mapped and
    /// decoded with its original compatibility implementation.
    @discardableResult
    static func read(
        from sourceURL: URL,
        password: String,
        onRecord: @escaping (StoredRecordSnapshot) throws -> Void
    ) throws -> Metadata {
        let byteCount = try fileByteCount(at: sourceURL)
        guard PortableArchive.isWithinArchiveByteLimit(byteCount) else {
            throw PortableArchiveError.archiveTooLarge
        }
        guard byteCount > PortableArchive.magic.count else {
            throw PortableArchiveError.invalidArchive
        }

        let probeHandle = try FileHandle(forReadingFrom: sourceURL)
        let probe: Data
        do {
            probe = try readExactly(
                PortableArchive.magic.count + 1,
                from: probeHandle
            )
            try probeHandle.close()
        } catch {
            try? probeHandle.close()
            throw error
        }
        guard probe.prefix(PortableArchive.magic.count)
            == PortableArchive.magic else {
            throw PortableArchiveError.invalidArchive
        }
        let discriminator = probe[PortableArchive.magic.count]
        if discriminator == UInt8(ascii: "{") {
            guard byteCount <= PortableArchive.maximumLegacyArchiveByteCount else {
                throw PortableArchiveError.archiveTooLarge
            }
            let mapped = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            let snapshot = try PortableArchive.openVersionOne(
                mapped,
                password: password
            )
            for (index, record) in snapshot.records.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                try onRecord(record)
            }
            let metrics = try metrics(for: snapshot.records)
            return try metadata(
                schemaVersion: snapshot.schemaVersion,
                createdAt: snapshot.createdAt,
                metrics: metrics
            )
        }
        guard discriminator == UInt8(PortableArchive.currentVersion) else {
            throw PortableArchiveError.unsupportedVersion(Int(discriminator))
        }

        return try readVersionTwo(
            from: sourceURL,
            fileByteCount: byteCount,
            password: password,
            onRecord: onRecord
        )
    }

    private static func readVersionTwo(
        from sourceURL: URL,
        fileByteCount: Int,
        password: String,
        onRecord: @escaping (StoredRecordSnapshot) throws -> Void
    ) throws -> Metadata {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        let encodedHeader = try readExactly(headerByteCount, from: handle)
        let header = try parseHeader(encodedHeader, fileByteCount: fileByteCount)

        let (_, passwordData) = PortableArchive.normalizedPassword(password)
        // Restore does not enforce the creation-time minimum because a short
        // wrong password must be indistinguishable from any other wrong one.
        guard passwordData.count <= PortableArchive.maximumPasswordByteCount else {
            throw PortableArchiveError.authenticationFailed
        }
        let key = try PortableArchive.deriveKey(
            passwordData: passwordData,
            salt: header.salt,
            iterations: PortableArchive.iterationCount
        )
        let decoder = RecordStreamDecoder(
            expectedMetadata: header.metadata,
            onRecord: onRecord
        )

        for chunkIndex in 0..<header.metadata.chunkCount {
            try Task.checkCancellation()
            let lengthData = try readExactly(framePrefixByteCount, from: handle)
            let plaintextLength = Int(try decodeUInt32(lengthData))
            let expectedLength = expectedPlaintextLength(
                chunkIndex: chunkIndex,
                metadata: header.metadata
            )
            guard plaintextLength == expectedLength else {
                throw PortableArchiveError.invalidArchive
            }
            let ciphertext = try readExactly(plaintextLength, from: handle)
            let tag = try readExactly(tagByteCount, from: handle)
            let nonce = try nonce(prefix: header.noncePrefix, index: chunkIndex)
            let box: AES.GCM.SealedBox
            do {
                box = try AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                )
            } catch {
                throw PortableArchiveError.invalidArchive
            }
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(
                    box,
                    using: key,
                    authenticating: associatedData(
                        header: header.encoded,
                        chunkIndex: chunkIndex,
                        plaintextLength: plaintextLength
                    )
                )
            } catch {
                try Task.checkCancellation()
                throw PortableArchiveError.authenticationFailed
            }
            try decoder.append(plaintext)
        }
        try decoder.finish()
        let trailing = try handle.read(upToCount: 1) ?? Data()
        guard trailing.isEmpty else {
            throw PortableArchiveError.invalidArchive
        }
        return header.metadata
    }

    private final class ChunkWriter {
        private let handle: FileHandle
        private let header: Header
        private let key: SymmetricKey
        private var buffer = Data()
        private var chunkIndex = 0
        private var recordCount = 0
        private var payloadByteCount = 0
        private var plaintextByteCount = 0

        init(handle: FileHandle, header: Header, key: SymmetricKey) {
            self.handle = handle
            self.header = header
            self.key = key
            buffer.reserveCapacity(chunkByteCount)
        }

        func append(_ record: StoredRecordSnapshot) throws {
            let collection = Data(record.collection.utf8)
            let recordID = Data(record.recordID.utf8)
            try validate(
                record: record,
                collectionByteCount: collection.count,
                recordIDByteCount: recordID.count
            )
            var encodedHeader = Data()
            encodedHeader.reserveCapacity(recordHeaderByteCount)
            encodedHeader.appendBigEndian(UInt32(collection.count))
            encodedHeader.appendBigEndian(UInt32(recordID.count))
            encodedHeader.appendBigEndian(UInt64(record.payload.count))
            encodedHeader.appendBigEndian(record.updatedAt.bitPattern)
            try appendBytes(encodedHeader)
            try appendBytes(collection)
            try appendBytes(recordID)
            try appendBytes(record.payload)
            recordCount = try checkedAdd(recordCount, 1)
            payloadByteCount = try checkedAdd(
                payloadByteCount,
                record.payload.count
            )
        }

        func finish() throws {
            guard recordCount == header.metadata.recordCount,
                  payloadByteCount == header.metadata.payloadByteCount,
                  plaintextByteCount + buffer.count
                    == header.metadata.plaintextByteCount else {
                throw PortableArchiveError.invalidArchive
            }
            // A zero-length authenticated frame protects even an empty book's
            // header. Non-empty streams flush their final partial/full chunk.
            if !buffer.isEmpty || chunkIndex == 0 {
                try flush()
            }
            guard chunkIndex == header.metadata.chunkCount else {
                throw PortableArchiveError.invalidArchive
            }
            try handle.synchronize()
        }

        private func appendBytes(_ data: Data) throws {
            var sourceOffset = 0
            while sourceOffset < data.count {
                try Task.checkCancellation()
                let available = chunkByteCount - buffer.count
                let amount = min(available, data.count - sourceOffset)
                let end = sourceOffset + amount
                let startIndex = data.index(
                    data.startIndex,
                    offsetBy: sourceOffset
                )
                let endIndex = data.index(data.startIndex, offsetBy: end)
                buffer.append(contentsOf: data[startIndex..<endIndex])
                sourceOffset = end
                if buffer.count == chunkByteCount {
                    try flush()
                }
            }
        }

        private func flush() throws {
            guard chunkIndex < header.metadata.chunkCount else {
                throw PortableArchiveError.invalidArchive
            }
            let plaintext = buffer
            let plaintextLength = plaintext.count
            let nonce = try PortableArchiveV2.nonce(
                prefix: header.noncePrefix,
                index: chunkIndex
            )
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: associatedData(
                    header: header.encoded,
                    chunkIndex: chunkIndex,
                    plaintextLength: plaintextLength
                )
            )
            var prefix = Data()
            prefix.appendBigEndian(UInt32(plaintextLength))
            try handle.write(contentsOf: prefix)
            try handle.write(contentsOf: sealed.ciphertext)
            try handle.write(contentsOf: sealed.tag)
            plaintextByteCount = try checkedAdd(
                plaintextByteCount,
                plaintextLength
            )
            chunkIndex += 1
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private final class RecordStreamDecoder {
        private let expected: Metadata
        private let onRecord: (StoredRecordSnapshot) throws -> Void
        private var buffer = Data()
        private var readOffset = 0
        private var recordCount = 0
        private var payloadByteCount = 0
        private var plaintextByteCount = 0

        init(
            expectedMetadata: Metadata,
            onRecord: @escaping (StoredRecordSnapshot) throws -> Void
        ) {
            expected = expectedMetadata
            self.onRecord = onRecord
            buffer.reserveCapacity(chunkByteCount + maximumRecordPayloadByteCount)
        }

        func append(_ plaintext: Data) throws {
            plaintextByteCount = try checkedAdd(
                plaintextByteCount,
                plaintext.count
            )
            guard plaintextByteCount <= expected.plaintextByteCount else {
                throw PortableArchiveError.invalidArchive
            }
            buffer.append(plaintext)
            try decodeAvailableRecords()
        }

        func finish() throws {
            try decodeAvailableRecords()
            guard readOffset == buffer.count,
                  recordCount == expected.recordCount,
                  payloadByteCount == expected.payloadByteCount,
                  plaintextByteCount == expected.plaintextByteCount else {
                throw PortableArchiveError.invalidArchive
            }
        }

        private func decodeAvailableRecords() throws {
            while buffer.count - readOffset >= recordHeaderByteCount,
                  recordCount < expected.recordCount {
                let headerStart = readOffset
                let collectionLength = Int(try buffer.decodeUInt32(at: headerStart))
                let recordIDLength = Int(
                    try buffer.decodeUInt32(at: headerStart + 4)
                )
                let payloadLength64 = try buffer.decodeUInt64(at: headerStart + 8)
                guard payloadLength64 <= UInt64(Int.max) else {
                    throw PortableArchiveError.invalidArchive
                }
                let payloadLength = Int(payloadLength64)
                let timeBits = try buffer.decodeUInt64(at: headerStart + 16)
                guard collectionLength > 0,
                      collectionLength <= maximumCollectionByteCount,
                      recordIDLength > 0,
                      recordIDLength <= maximumRecordIDByteCount,
                      payloadLength > 0,
                      payloadLength <= maximumRecordPayloadByteCount else {
                    throw PortableArchiveError.invalidArchive
                }
                let bodyLength = try checkedAdd(
                    try checkedAdd(collectionLength, recordIDLength),
                    payloadLength
                )
                let recordLength = try checkedAdd(recordHeaderByteCount, bodyLength)
                guard buffer.count - readOffset >= recordLength else { break }

                var cursor = headerStart + recordHeaderByteCount
                let collectionData = Data(buffer[cursor..<cursor + collectionLength])
                cursor += collectionLength
                let recordIDData = Data(buffer[cursor..<cursor + recordIDLength])
                cursor += recordIDLength
                let payload = Data(buffer[cursor..<cursor + payloadLength])
                guard let collection = String(
                        data: collectionData,
                        encoding: .utf8
                      ),
                      let recordID = String(data: recordIDData, encoding: .utf8),
                      !collection.isEmpty,
                      !recordID.isEmpty else {
                    throw PortableArchiveError.invalidArchive
                }
                let updatedAt = Double(bitPattern: timeBits)
                guard updatedAt.isFinite else {
                    throw PortableArchiveError.invalidArchive
                }
                try onRecord(StoredRecordSnapshot(
                    collection: collection,
                    recordID: recordID,
                    payload: payload,
                    updatedAt: updatedAt
                ))
                recordCount = try checkedAdd(recordCount, 1)
                payloadByteCount = try checkedAdd(payloadByteCount, payloadLength)
                readOffset += recordLength

                if readOffset >= chunkByteCount {
                    buffer.removeSubrange(0..<readOffset)
                    readOffset = 0
                }
            }
        }
    }

    private static func metrics(
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

    private static func metadata(
        schemaVersion: Int32,
        createdAt: Date,
        metrics: DatabaseStorageMetrics
    ) throws -> Metadata {
        guard schemaVersion >= 0,
              createdAt.timeIntervalSince1970.isFinite,
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
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            recordCount: metrics.recordCount,
            payloadByteCount: metrics.payloadByteCount,
            plaintextByteCount: plaintextByteCount,
            chunkCount: chunkCount
        )
    }

    private static func makeHeader(
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
        encoded.appendBigEndian(metadata.createdAt.timeIntervalSince1970.bitPattern)
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

    private static func parseHeader(
        _ encoded: Data,
        fileByteCount: Int
    ) throws -> Header {
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
        guard cursor == headerByteCount else {
            throw PortableArchiveError.invalidArchive
        }
        let metrics = DatabaseStorageMetrics(
            recordCount: recordCount,
            payloadByteCount: Int(payloadByteCount64),
            recordIDByteCount: 0,
            collectionByteCount: 0
        )
        let createdAt = Date(
            timeIntervalSince1970: Double(bitPattern: createdAtBits)
        )
        let metadata = Metadata(
            schemaVersion: Int32(bitPattern: schemaBits),
            createdAt: createdAt,
            recordCount: metrics.recordCount,
            payloadByteCount: metrics.payloadByteCount,
            plaintextByteCount: Int(plaintextByteCount64),
            chunkCount: chunkCount
        )
        let expectedChunkCount = max(
            1,
            try checkedAdd(
                metadata.plaintextByteCount,
                chunkByteCount - 1
            ) / chunkByteCount
        )
        guard metadata.schemaVersion >= 0,
              metadata.createdAt.timeIntervalSince1970.isFinite,
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
        return Header(
            metadata: metadata,
            salt: salt,
            noncePrefix: noncePrefix,
            encoded: encoded
        )
    }

    private static func validate(
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

    private static func expectedPlaintextLength(
        chunkIndex: Int,
        metadata: Metadata
    ) -> Int {
        if chunkIndex < metadata.chunkCount - 1 { return chunkByteCount }
        return metadata.plaintextByteCount
            - (metadata.chunkCount - 1) * chunkByteCount
    }

    private static func associatedData(
        header: Data,
        chunkIndex: Int,
        plaintextLength: Int
    ) -> Data {
        var data = header
        data.appendBigEndian(UInt32(chunkIndex))
        data.appendBigEndian(UInt32(plaintextLength))
        return data
    }

    private static func nonce(
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

    private static func writeAtomically(
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
            contents: nil
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
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        committed = true
    }

    private static func fileByteCount(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let byteCount = values.fileSize, byteCount >= 0 else {
            throw PortableArchiveError.invalidArchive
        }
        return byteCount
    }

    private static func readExactly(
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

    private static func decodeUInt32(_ data: Data) throws -> UInt32 {
        try data.decodeUInt32(at: 0)
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, result >= 0 else {
            throw PortableArchiveError.archiveTooLarge
        }
        return result
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow, result >= 0 else {
            throw PortableArchiveError.archiveTooLarge
        }
        return result
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    func decodeUInt16(at offset: Int) throws -> UInt16 {
        try decodeFixedWidth(UInt16.self, at: offset)
    }

    func decodeUInt32(at offset: Int) throws -> UInt32 {
        try decodeFixedWidth(UInt32.self, at: offset)
    }

    func decodeUInt64(at offset: Int) throws -> UInt64 {
        try decodeFixedWidth(UInt64.self, at: offset)
    }

    private func decodeFixedWidth<T: FixedWidthInteger>(
        _ type: T.Type,
        at offset: Int
    ) throws -> T {
        let width = MemoryLayout<T>.size
        guard offset >= 0, offset <= count - width else {
            throw PortableArchiveError.invalidArchive
        }
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { destination in
            _ = copyBytes(
                to: destination,
                from: offset..<(offset + width)
            )
        }
        return T(bigEndian: value)
    }
}
