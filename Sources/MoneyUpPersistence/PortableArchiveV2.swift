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
        let archiveVersion: Int
        let schemaVersion: Int32
        let createdAt: Date
        let recordCount: Int
        let payloadByteCount: Int
        let plaintextByteCount: Int
        let chunkCount: Int
    }

    struct Header {
        let metadata: Metadata
        let salt: Data
        let noncePrefix: Data
        let encoded: Data
    }

    static let recordHeaderByteCount = 24
    static let flags: UInt8 = 0

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
            let currentMetadata = try metadata(
                schemaVersion: snapshot.schemaVersion,
                createdAt: snapshot.createdAt,
                metrics: metrics
            )
            return Metadata(
                archiveVersion: PortableArchive.legacyVersion,
                schemaVersion: currentMetadata.schemaVersion,
                createdAt: currentMetadata.createdAt,
                recordCount: currentMetadata.recordCount,
                payloadByteCount: currentMetadata.payloadByteCount,
                plaintextByteCount: currentMetadata.plaintextByteCount,
                chunkCount: currentMetadata.chunkCount
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

    static func readVersionTwo(
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

    final class ChunkWriter {
        let handle: FileHandle
        let header: Header
        let key: SymmetricKey
        var buffer = Data()
        var chunkIndex = 0
        var recordCount = 0
        var payloadByteCount = 0
        var plaintextByteCount = 0

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

        func appendBytes(_ data: Data) throws {
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

        func flush() throws {
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

    final class RecordStreamDecoder {
        let expected: Metadata
        let onRecord: (StoredRecordSnapshot) throws -> Void
        var buffer = Data()
        var readOffset = 0
        var recordCount = 0
        var payloadByteCount = 0
        var plaintextByteCount = 0

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

        func decodeAvailableRecords() throws {
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
}

extension Data {
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
