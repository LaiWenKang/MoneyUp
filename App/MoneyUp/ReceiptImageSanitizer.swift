import CoreGraphics
import Foundation
import ImageIO
import MoneyUpCore
import UniformTypeIdentifiers

/// Produces the optional encrypted attachment from a transient Photos payload.
/// Pixels are decoded with orientation applied, bounded, and re-encoded from a
/// new `CGImage`. No source property dictionary crosses this boundary, so GPS,
/// EXIF, TIFF device identifiers, captions, and edit-history metadata are not
/// retained with the transaction or copied into portable backups.
enum ReceiptImageSanitizer {
    static let maximumPixelDimension = 4_096
    private static let jpegQuality = 0.9

    /// Runs the synchronous ImageIO boundary on one shared serial actor. The
    /// work remains part of the caller's task, so cancellation reaches every
    /// checkpoint without leaving an unowned encode behind after a view exits.
    static func prepareForEncryptedStorage(
        _ data: Data,
        sanitizer: @escaping @Sendable (Data) throws -> Data = {
            try ReceiptImageSanitizer.sanitizedForEncryptedStorage($0)
        }
    ) async throws -> Data {
        try Task.checkCancellation()
        let sanitized = try await ReceiptSanitizationExecutor.shared.run(
            data,
            sanitizer: sanitizer
        )
        try Task.checkCancellation()
        return sanitized
    }

    /// Lets a replacement scan wait only for an older retention decode, not
    /// for an obsolete Photos transfer or OCR request. This keeps large image
    /// decodes serialized without making a slow canceled scan block the latest
    /// selection end to end.
    static func waitForPendingPreparation() async throws {
        try Task.checkCancellation()
        try await ReceiptSanitizationExecutor.shared.waitUntilAvailable()
        try Task.checkCancellation()
    }

    static func sanitizedForEncryptedStorage(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw ReceiptAttachmentError.emptyData }
        guard data.count <= ReceiptAttachment.maximumByteCount else {
            throw ReceiptAttachmentError.tooLarge
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        let sourceType = CGImageSourceGetType(source)
        let preservesPNG = sourceType.map { $0 as String }
            == UTType.png.identifier
        let outputType = (
            preservesPNG ? UTType.png.identifier : UTType.jpeg.identifier
        ) as CFString
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        try Task.checkCancellation()

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            outputType,
            1,
            nil
        ) else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        let outputProperties: CFDictionary
        if preservesPNG {
            outputProperties = [:] as CFDictionary
        } else {
            outputProperties = [
                kCGImageDestinationLossyCompressionQuality: jpegQuality
            ] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, outputProperties)
        guard CGImageDestinationFinalize(destination) else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        try Task.checkCancellation()
        let sanitized = output as Data
        guard !sanitized.isEmpty else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        guard sanitized.count <= ReceiptAttachment.maximumByteCount else {
            throw ReceiptAttachmentError.tooLarge
        }
        guard ReceiptAttachmentMediaType.detected(from: sanitized) != .unknown else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        return sanitized
    }
}

/// A synchronous actor-isolated job never yields while ImageIO owns its large
/// bitmap. Rapid rescans and newly constructed Log views therefore cannot run
/// two retention decodes concurrently, even when the older view has vanished.
private actor ReceiptSanitizationExecutor {
    static let shared = ReceiptSanitizationExecutor()

    func run(
        _ data: Data,
        sanitizer: @Sendable (Data) throws -> Data
    ) throws -> Data {
        try Task.checkCancellation()
        return try sanitizer(data)
    }

    func waitUntilAvailable() throws {
        try Task.checkCancellation()
    }
}
