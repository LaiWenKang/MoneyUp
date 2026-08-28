import Foundation

public enum ReceiptAttachmentMediaType: String, Codable, CaseIterable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"
    case unknown = "application/octet-stream"

    public static func detected(from data: Data) -> ReceiptAttachmentMediaType {
        if data.starts(with: [0xff, 0xd8, 0xff]) { return .jpeg }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            return .png
        }
        guard data.count >= 16,
              data[4..<8].elementsEqual("ftyp".utf8) else {
            return .unknown
        }
        // `ftyp` identifies the broad ISO base-media family, not HEIC. AVIF
        // and other formats use the same box, so require an actual HEIF/HEVC
        // compatible brand instead of assigning a false image/heic MIME type.
        let heicBrands: Set<String> = [
            "heic", "heix", "hevc", "hevx", "heim", "heis"
        ]
        guard let standardSize = unsignedInteger32(from: data, at: 0) else {
            return .unknown
        }
        let brandStart: Int
        let boxEnd: Int
        switch standardSize {
        case 0:
            brandStart = 8
            boxEnd = data.count
        case 1:
            guard let extendedSize = unsignedInteger64(from: data, at: 8),
                  extendedSize >= 24,
                  extendedSize <= UInt64(data.count) else {
                return .unknown
            }
            brandStart = 16
            boxEnd = Int(extendedSize)
        default:
            guard standardSize >= 16,
                  UInt64(standardSize) <= UInt64(data.count) else {
                return .unknown
            }
            brandStart = 8
            boxEnd = Int(standardSize)
        }
        guard brandStart + 8 <= boxEnd else { return .unknown }

        if let majorBrand = asciiBrand(in: data, at: brandStart),
           heicBrands.contains(majorBrand) {
            return .heic
        }
        // Skip the four-byte minor version after the major brand. Scan only
        // compatible brands declared inside this `ftyp` box; bytes in later
        // media payloads must never influence MIME detection.
        for offset in stride(from: brandStart + 8, to: boxEnd, by: 4)
        where offset + 4 <= boxEnd {
            if let brand = asciiBrand(in: data, at: offset),
               heicBrands.contains(brand) {
                return .heic
            }
        }
        return .unknown
    }

    private static func asciiBrand(in data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
    }

    private static func unsignedInteger32(from data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data[offset..<(offset + 4)].reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func unsignedInteger64(from data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data[offset..<(offset + 8)].reduce(UInt64.zero) {
            ($0 << 8) | UInt64($1)
        }
    }
}

public enum ReceiptAttachmentError: Error, Equatable, Sendable {
    case emptyData
    case tooLarge
    case invalidMetadata
}

/// Small, encrypted-index projection used by lists and exports. Receipt image
/// bytes are fetched only when a particular attachment is opened.
public struct ReceiptAttachmentMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let entryID: UUID
    public let mediaType: ReceiptAttachmentMediaType
    public let byteCount: Int
    public let createdAt: Date

    public init(
        id: UUID,
        entryID: UUID,
        mediaType: ReceiptAttachmentMediaType,
        byteCount: Int,
        createdAt: Date
    ) throws {
        guard byteCount > 0,
              byteCount <= ReceiptAttachment.maximumByteCount,
              createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        self.id = id
        self.entryID = entryID
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.createdAt = createdAt
    }

    public init(_ attachment: ReceiptAttachment) {
        id = attachment.id
        entryID = attachment.entryID
        mediaType = attachment.mediaType
        byteCount = attachment.data.count
        createdAt = attachment.createdAt
    }

    public func relinked(to entryID: UUID) throws -> ReceiptAttachmentMetadata {
        try ReceiptAttachmentMetadata(
            id: id,
            entryID: entryID,
            mediaType: mediaType,
            byteCount: byteCount,
            createdAt: createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, entryID, mediaType, byteCount, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                entryID: container.decode(UUID.self, forKey: .entryID),
                mediaType: container.decode(
                    ReceiptAttachmentMediaType.self,
                    forKey: .mediaType
                ),
                byteCount: container.decode(Int.self, forKey: .byteCount),
                createdAt: container.decode(Date.self, forKey: .createdAt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .byteCount,
                in: container,
                debugDescription: "Receipt metadata failed validation."
            )
        }
    }
}

/// Receipt bytes are deliberately a record separate from the journal entry.
/// The persistence layer encrypts this payload with SQLCipher and portable
/// backup encrypts the resulting snapshot again with the user's password.
public struct ReceiptAttachment: Codable, Equatable, Identifiable, Sendable {
    public static let maximumByteCount = 15_000_000

    public let id: UUID
    public let entryID: UUID
    public let mediaType: ReceiptAttachmentMediaType
    public let data: Data
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        entryID: UUID,
        mediaType: ReceiptAttachmentMediaType,
        data: Data,
        createdAt: Date = Date()
    ) throws {
        guard !data.isEmpty else { throw ReceiptAttachmentError.emptyData }
        guard data.count <= Self.maximumByteCount else {
            throw ReceiptAttachmentError.tooLarge
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        self.id = id
        self.entryID = entryID
        self.mediaType = mediaType
        self.data = data
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, entryID, mediaType, data, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                entryID: container.decode(UUID.self, forKey: .entryID),
                mediaType: container.decode(
                    ReceiptAttachmentMediaType.self,
                    forKey: .mediaType
                ),
                data: container.decode(Data.self, forKey: .data),
                createdAt: container.decode(Date.self, forKey: .createdAt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "Receipt attachment failed size or content validation."
            )
        }
    }
}
