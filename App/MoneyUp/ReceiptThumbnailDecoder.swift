import CoreGraphics
import Foundation
import ImageIO
import MoneyUpCore
import UIKit

/// A decoded, orientation-normalized receipt preview whose longest edge is
/// bounded before UIKit receives it. The wrapper is immutable and owns a
/// retained `CGImage`; Core Graphics images are safe to hand between the
/// detached decoder and the main actor once construction has completed.
struct DecodedReceiptThumbnail: @unchecked Sendable {
    let cgImage: CGImage

    var pixelWidth: Int { cgImage.width }
    var pixelHeight: Int { cgImage.height }
}

enum ReceiptThumbnailDecoder {
    /// The receipt preview is displayed at no more than 240 points high. A
    /// 1,200-pixel edge remains sharp on high-density displays while bounding
    /// the decoded bitmap to roughly 5.5 MiB in the square worst case.
    static let defaultMaximumPixelDimension = 1_200

    /// Performs ImageIO source parsing and thumbnail decompression outside the
    /// main actor. `kCGImageSourceCreateThumbnailWithTransform` applies EXIF/
    /// HEIF orientation so UIKit can always present an upright `.up` image.
    static func decode(
        _ data: Data,
        maximumPixelDimension: Int = defaultMaximumPixelDimension
    ) async throws -> DecodedReceiptThumbnail {
        guard !data.isEmpty else { throw ReceiptAttachmentError.emptyData }
        guard data.count <= ReceiptAttachment.maximumByteCount else {
            throw ReceiptAttachmentError.tooLarge
        }
        guard maximumPixelDimension > 0 else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        try Task.checkCancellation()

        let thumbnail = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                try Self.decodeSynchronously(
                    data,
                    maximumPixelDimension: maximumPixelDimension
                )
            }
        }.value

        try Task.checkCancellation()
        return thumbnail
    }

    @MainActor
    static func image(
        from data: Data,
        maximumPixelDimension: Int = defaultMaximumPixelDimension
    ) async throws -> UIImage {
        let thumbnail = try await decode(
            data,
            maximumPixelDimension: maximumPixelDimension
        )
        try Task.checkCancellation()
        return UIImage(
            cgImage: thumbnail.cgImage,
            scale: 1,
            orientation: .up
        )
    }

    private static func decodeSynchronously(
        _ data: Data,
        maximumPixelDimension: Int
    ) throws -> DecodedReceiptThumbnail {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw ReceiptAttachmentError.invalidMetadata
        }

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
        ), image.width > 0, image.height > 0,
           max(image.width, image.height) <= maximumPixelDimension else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        return DecodedReceiptThumbnail(cgImage: image)
    }
}
