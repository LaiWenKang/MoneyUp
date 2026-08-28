import CoreGraphics
import Foundation
import ImageIO
@testable import MoneyUp
import MoneyUpCore
import XCTest

final class ReceiptThumbnailDecoderTests: XCTestCase {
    func testDecoderBoundsLongestEdgeAndPreservesAspectRatio() async throws {
        let source = try makeImage(width: 2_400, height: 1_200)
        let data = try jpegData(from: source)

        let thumbnail = try await ReceiptThumbnailDecoder.decode(
            data,
            maximumPixelDimension: 600
        )

        XCTAssertEqual(thumbnail.pixelWidth, 600)
        XCTAssertEqual(thumbnail.pixelHeight, 300)
    }

    func testDecoderAppliesSourceOrientation() async throws {
        let source = try makeImage(width: 80, height: 40)
        let data = try jpegData(
            from: source,
            orientation: .right
        )

        let thumbnail = try await ReceiptThumbnailDecoder.decode(
            data,
            maximumPixelDimension: 200
        )

        XCTAssertEqual(thumbnail.pixelWidth, 40)
        XCTAssertEqual(thumbnail.pixelHeight, 80)
    }

    func testDecoderRejectsEmptyOversizedAndUnreadableData() async {
        await assertDecodeError(.emptyData, data: Data())
        await assertDecodeError(
            .tooLarge,
            data: Data(
                repeating: 0,
                count: ReceiptAttachment.maximumByteCount + 1
            )
        )
        await assertDecodeError(
            .invalidMetadata,
            data: Data("not an image".utf8)
        )
    }

    private func assertDecodeError(
        _ expected: ReceiptAttachmentError,
        data: Data
    ) async {
        do {
            _ = try await ReceiptThumbnailDecoder.decode(data)
            XCTFail("Expected receipt thumbnail decoding to fail.")
        } catch let error as ReceiptAttachmentError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
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
        context.setFillColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1)
        context.fill(
            CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private func jpegData(
        from image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw TestError.imageEncodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyOrientation: orientation.rawValue
        ]
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
    }
}
