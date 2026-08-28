import CoreGraphics
import Foundation
import ImageIO
@testable import MoneyUp
import MoneyUpCore
import UniformTypeIdentifiers
import XCTest

final class ReceiptImageSanitizerTests: XCTestCase {
    func testSanitizerRemovesLocationEXIFAndDeviceMetadata() throws {
        let source = try makeImage(width: 320, height: 180)
        let original = try jpegData(
            from: source,
            properties: [
                kCGImagePropertyGPSDictionary as String: [
                    kCGImagePropertyGPSLatitude as String: 1.3521,
                    kCGImagePropertyGPSLatitudeRef as String: "N",
                    kCGImagePropertyGPSLongitude as String: 103.8198,
                    kCGImagePropertyGPSLongitudeRef as String: "E"
                ],
                kCGImagePropertyExifDictionary as String: [
                    kCGImagePropertyExifUserComment as String:
                        "private receipt annotation"
                ],
                kCGImagePropertyTIFFDictionary as String: [
                    kCGImagePropertyTIFFMake as String: "Private Camera Maker",
                    kCGImagePropertyTIFFModel as String: "Private Device Model"
                ]
            ]
        )
        let originalProperties = try properties(in: original)
        XCTAssertNotNil(
            originalProperties[kCGImagePropertyGPSDictionary as String]
        )

        let sanitized = try ReceiptImageSanitizer
            .sanitizedForEncryptedStorage(original)
        let sanitizedProperties = try properties(in: sanitized)

        XCTAssertEqual(
            ReceiptAttachmentMediaType.detected(from: sanitized),
            .jpeg
        )
        XCTAssertNil(
            sanitizedProperties[kCGImagePropertyGPSDictionary as String]
        )
        let exif = sanitizedProperties[
            kCGImagePropertyExifDictionary as String
        ] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
        let tiff = sanitizedProperties[
            kCGImagePropertyTIFFDictionary as String
        ] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake as String])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel as String])
    }

    func testSanitizerAppliesOrientationAndBoundsRetainedPixels() throws {
        let original = try jpegData(
            from: makeImage(width: 5_000, height: 2_500),
            properties: [
                kCGImagePropertyOrientation as String:
                    CGImagePropertyOrientation.right.rawValue
            ]
        )

        let sanitized = try ReceiptImageSanitizer
            .sanitizedForEncryptedStorage(original)
        guard let source = CGImageSourceCreateWithData(
            sanitized as CFData,
            nil
        ),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("Sanitized receipt was not decodable.")
        }

        XCTAssertEqual(image.width, 2_048)
        XCTAssertEqual(image.height, 4_096)
        let sanitizedProperties = try properties(in: sanitized)
        let orientation = sanitizedProperties[
            kCGImagePropertyOrientation as String
        ] as? NSNumber
        XCTAssertTrue(orientation == nil || orientation?.intValue == 1)
    }

    private func properties(in data: Data) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [String: Any] else {
            throw TestError.imageDecodingFailed
        }
        return properties
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.imageCreationFailed
        }
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private func jpegData(
        from image: CGImage,
        properties: [String: Any]
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TestError.imageEncodingFailed
        }
        var properties = properties
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.9
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.imageEncodingFailed
        }
        return output as Data
    }

    private enum TestError: Error {
        case imageCreationFailed
        case imageEncodingFailed
        case imageDecodingFailed
    }
}
