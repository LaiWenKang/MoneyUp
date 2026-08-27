import Foundation

public enum ReceiptAttachmentMediaType: String, Codable, CaseIterable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"

    public static func detected(from data: Data) -> ReceiptAttachmentMediaType {
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return .png }
        if data.count >= 12,
           String(decoding: data[4..<12], as: UTF8.self).contains("ftyp") {
            return .heic
        }
        return .jpeg
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
